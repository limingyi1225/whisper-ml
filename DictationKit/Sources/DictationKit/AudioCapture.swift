// `@preconcurrency`: AVAudioConverter's input block is @Sendable in the SDK, but the
// buffer it captures is used synchronously within the call — safe, and not worth an
// unsafe-pointer dance to express.
@preconcurrency import AVFoundation
import OSLog

private nonisolated let log = Logger(subsystem: "com.mingyili.Whisper", category: "audio")

/// Identifies one attempt to rebuild the audio engine within one capture gesture.
/// The generation prevents delayed work from crossing gesture boundaries; the epoch
/// distinguishes multiple configuration changes during the same gesture.
nonisolated struct AudioCaptureRestartAttempt: Equatable, Sendable {
    let captureGeneration: UInt64
    let restartEpoch: UInt64
}

/// Pure lifecycle checks shared by the deferred restart and its watchdog. Keeping
/// these checks independent of AVAudioEngine makes the stale-callback behavior
/// deterministic to test without opening the microphone.
nonisolated enum AudioCaptureRestartPolicy {
    static func isCurrent(
        _ attempt: AudioCaptureRestartAttempt,
        activeCaptureGeneration: UInt64?,
        currentRestartEpoch: UInt64
    ) -> Bool {
        activeCaptureGeneration == attempt.captureGeneration
            && currentRestartEpoch == attempt.restartEpoch
    }

    static func shouldReportStalledCapture(
        _ attempt: AudioCaptureRestartAttempt,
        activeCaptureGeneration: UInt64?,
        currentRestartEpoch: UInt64,
        deliveredBuffersBefore: UInt64,
        deliveredBuffersNow: UInt64,
        isRunning: Bool,
        captureFailureReported: Bool
    ) -> Bool {
        isRunning
            && !captureFailureReported
            && deliveredBuffersNow == deliveredBuffersBefore
            && isCurrent(
                attempt,
                activeCaptureGeneration: activeCaptureGeneration,
                currentRestartEpoch: currentRestartEpoch
            )
    }

    static func newlyLatchedFailureGeneration(
        wasReported: Bool,
        isReported: Bool,
        activeCaptureGeneration: UInt64?
    ) -> UInt64? {
        !wasReported && isReported ? activeCaptureGeneration : nil
    }
}

/// Captures the default input device and hands back 24 kHz mono PCM16 — the format the
/// Realtime transcription session expects.
///
/// Capture starts the moment the trigger key goes down, before we know whether this is a
/// real dictation gesture. Audio recorded during that window goes into a pre-roll buffer;
/// if the long press is confirmed we flush it so the first syllable is never clipped, and
/// if it turns out to be a plain modifier tap we throw it away.
///
/// Explicitly `nonisolated`: the project defaults types to `@MainActor`, but the tap
/// callback runs on the audio render thread, so this class must not be actor-isolated.
/// `@unchecked Sendable` because the cross-thread state (pre-roll buffer, converter,
/// streaming flag) is guarded by `lock`; engine control (`isRunning`, tap install) is
/// only ever touched from the main thread.
public nonisolated final class AudioCapture: @unchecked Sendable {
    /// 24 kHz mono PCM16 → 48 000 bytes per second.
    public static let bytesPerSecond = 48_000

    /// Delivered on an internal queue, not the main thread.
    public var onChunk: ((Data) -> Void)?
    /// 0...1 loudness for the HUD, delivered on the main thread.
    public var onLevel: ((Float) -> Void)?
    /// The engine failed to start, or died mid-capture and could not be restarted.
    /// No further audio will arrive; the controller must fail the utterance visibly
    /// rather than let a half-recorded sentence commit as if it were complete.
    /// May fire on any thread.
    public var onCaptureFailure: ((UInt64) -> Void)?

    public struct StopResult {
        public let audio: Data
        public let captureFailed: Bool
        public let generation: UInt64?
    }

    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )!

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var prerollChunks: [Data] = []
    private var prerollBytes = 0
    private var isStreaming = false
    private var isRunning = false
    private var captureFailureReported = false
    private var nextCaptureGeneration: UInt64 = 0
    private var activeCaptureGeneration: UInt64?
    private var configChangeObserver: NSObjectProtocol?
    /// Buffers the input tap has actually delivered. Only ever compared against a
    /// snapshot, so wraparound does not matter.
    private var deliveredBuffers: UInt64 = 0
    /// The configuration-change rebuild queued for the next main-queue turn.
    /// A token, rather than a Boolean, ensures a stale callback cannot consume a
    /// newer gesture's pending restart.
    private var configurationRestartPending: AudioCaptureRestartAttempt?
    private var configurationRestartEpoch: UInt64 = 0

    public init() {
        // The engine stops and deinitializes itself when the input device changes
        // (headset plugged in, Bluetooth mic switching). Without this, `isRunning`
        // would stay true while no audio flows, and the rest of the utterance would
        // be silently lost.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    /// Rebuilds capture after the input device changes.
    ///
    /// The notification is not the user yanking a headset out mid-sentence. Measured:
    /// the engine only runs while a gesture is held, and all three observed changes
    /// arrived with no `recording started` anywhere near them — the user had switched
    /// the input source while idle, and the change surfaced on the *next* press, when
    /// `beginPreroll` started the engine on hardware that had moved underneath it.
    /// So this path is on the critical path of an ordinary press, and failing it means
    /// the first press after every device switch dies with "microphone unavailable".
    ///
    /// Rebuilding the tap inline, inside the notification, never once worked: three
    /// restarts returned without throwing and then delivered no audio at all. Worse,
    /// `isRunning` stayed true over that dead tap, so the next press hit
    /// `beginPreroll`'s early return and inherited the corpse, and nothing found out
    /// until the 20 s transcription timeout — with every press in between queued behind
    /// an utterance that would never settle. That is what made the trigger key look
    /// dead until a relaunch.
    ///
    /// So: stop for real (`isRunning` false, no corpse to inherit), then rebuild on the
    /// next main-queue turn, once the engine has finished reconfiguring itself.
    private func handleConfigurationChange() {
        guard isRunning else { return }
        log.warning("input configuration changed; restarting engine")
        stopEngine()
        let (tail, failedGeneration): ([Data], UInt64?) = lock.withLock {
            let failureWasReported = captureFailureReported
            let tail = drainConverterLocked()
            return (
                tail,
                AudioCaptureRestartPolicy.newlyLatchedFailureGeneration(
                    wasReported: failureWasReported,
                    isReported: captureFailureReported,
                    activeCaptureGeneration: activeCaptureGeneration
                )
            )
        }
        routeConvertedChunks(tail)
        if let failedGeneration {
            // The engine is already stopped. Publishing immediately is essential:
            // the latch intentionally prevents the restart below, and the ordinary
            // one-shot reporter would now no-op because the drain set that latch.
            onCaptureFailure?(failedGeneration)
            return
        }

        let attempt: AudioCaptureRestartAttempt? = lock.withLock {
            guard let generation = activeCaptureGeneration, !captureFailureReported else {
                return nil
            }
            guard configurationRestartPending == nil else { return nil }
            configurationRestartEpoch &+= 1
            let attempt = AudioCaptureRestartAttempt(
                captureGeneration: generation,
                restartEpoch: configurationRestartEpoch
            )
            configurationRestartPending = attempt
            return attempt
        }
        guard let attempt else { return }
        DispatchQueue.main.async { [weak self] in
            self?.restartAfterConfigurationChange(attempt)
        }
    }

    private func restartAfterConfigurationChange(_ attempt: AudioCaptureRestartAttempt) {
        let stillWanted: Bool = lock.withLock {
            guard configurationRestartPending == attempt else { return false }
            configurationRestartPending = nil
            return !captureFailureReported
                && AudioCaptureRestartPolicy.isCurrent(
                    attempt,
                    activeCaptureGeneration: activeCaptureGeneration,
                    currentRestartEpoch: configurationRestartEpoch
                )
        }
        guard stillWanted, !isRunning else { return }
        guard startEngine() else {
            reportCaptureFailureOnce()
            return
        }
        verifyCaptureResumed(after: attempt)
    }

    /// How much audio to keep from before streaming starts. One second is plenty for
    /// the long-press threshold, but it is raised while a new utterance is queued
    /// behind an unfinished one so that waiting never costs the user their audio.
    private var prerollCapacityBytes = bytesPerSecond

    public func setPrerollCapacity(seconds: Int) {
        lock.withLock { prerollCapacityBytes = Self.bytesPerSecond * seconds }
    }

    // MARK: - Control

    /// Begins capturing into the pre-roll buffer. Nothing is emitted yet.
    @discardableResult
    public func beginPreroll() -> UInt64? {
        if isRunning {
            return lock.withLock { activeCaptureGeneration }
        }
        // `.armed` and `beginRecording` can both reach here. If a configuration
        // notification stopped the engine between those calls, keep ownership with
        // the same gesture and let its already-queued rebuild run next turn. Starting
        // inline here would bypass the deferral that lets AVAudioEngine settle.
        if let deferredGeneration = lock.withLock({
            configurationRestartPending == nil ? nil : activeCaptureGeneration
        }) {
            return deferredGeneration
        }
        // `.armed` and `beginRecording` both call this method. If the first attempt
        // failed, its callback is intentionally asynchronous; do not start (and report)
        // the same broken gesture a second time before the controller handles it.
        let generation: UInt64? = lock.withLock {
            guard !captureFailureReported else { return activeCaptureGeneration }
            nextCaptureGeneration &+= 1
            activeCaptureGeneration = nextCaptureGeneration
            prerollChunks.removeAll()
            prerollBytes = 0
            isStreaming = false
            return activeCaptureGeneration
        }
        guard let generation else { return nil }
        if !startEngine() { reportCaptureFailureOnce() }
        return generation
    }

    /// Installs a tap matching the input device's *current* format and starts the
    /// engine. Shared by the first start of a gesture and by the rebuild after a
    /// configuration change, so the two can never drift apart.
    private func startEngine() -> Bool {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            log.error("input node has no valid format (sampleRate=\(inputFormat.sampleRate)); is a mic present?")
            return false
        }
        guard lock.withLock({ makeConverterLocked(from: inputFormat) }) else { return false }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            return true
        } catch {
            log.error("engine start failed: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return false
        }
    }

    /// Puts the engine back in the state `startEngine` can start from. After this,
    /// `isRunning == false` is the truth, so nothing can inherit a tap that is no
    /// longer delivering.
    private func stopEngine() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// `engine.start()` returning without throwing does not mean the tap is delivering.
    /// Measured on this machine: after a configuration change the restart reported
    /// success and logged no error, while the relay received 0.9 s of audio for a 21 s
    /// utterance — the sentence was gone and nothing said so.
    ///
    /// The deferred rebuild is meant to fix that. This is the backstop for when it
    /// does not: the utterance cannot be saved here, but being told beats waiting out
    /// a 20 s transcription timeout for audio that is never coming.
    private func verifyCaptureResumed(after attempt: AudioCaptureRestartAttempt) {
        let before = lock.withLock { deliveredBuffers }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            let failedGeneration: UInt64? = self.lock.withLock {
                guard AudioCaptureRestartPolicy.shouldReportStalledCapture(
                    attempt,
                    activeCaptureGeneration: self.activeCaptureGeneration,
                    currentRestartEpoch: self.configurationRestartEpoch,
                    deliveredBuffersBefore: before,
                    deliveredBuffersNow: self.deliveredBuffers,
                    isRunning: self.isRunning,
                    captureFailureReported: self.captureFailureReported
                ) else {
                    return nil
                }
                self.captureFailureReported = true
                return attempt.captureGeneration
            }
            guard let failedGeneration else { return }
            log.error("no audio after the configuration-change restart; capture lost")
            self.stopEngine()
            self.onCaptureFailure?(failedGeneration)
        }
    }

    /// Promotes the session to live streaming and returns the buffered pre-roll audio.
    ///
    /// The optional next capacity is installed under the same lock, *after* the full
    /// buffered prefix has been detached. A queued gesture can have minutes of pre-roll;
    /// shrinking its buffer in a separate call before this transition would let the
    /// audio thread trim that already-spoken prefix down to the ordinary one-second cap.
    public func startStreaming(
        includePreroll: Bool,
        nextPrerollCapacitySeconds: Int? = nil
    ) -> Data {
        lock.withLock {
            isStreaming = true
            let preroll = includePreroll ? Data(prerollChunks.joined()) : Data()
            prerollChunks.removeAll()
            prerollBytes = 0
            if let nextPrerollCapacitySeconds {
                prerollCapacityBytes = Self.bytesPerSecond * max(0, nextPrerollCapacitySeconds)
            }
            return preroll
        }
    }

    /// Stops capture, then removes and returns everything in the pre-roll buffer.
    /// Used to freeze a queued utterance's audio the moment the key is released, so
    /// no later gesture can wipe it out of the shared buffer.
    ///
    /// Stop-then-drain, in that order: draining first would race the audio thread —
    /// a chunk converted but not yet appended would land after the drain and be
    /// cleared by the stop, eating the last syllable. `engine.stop()` blocks until
    /// an in-flight callback returns (measured, see `stop()`), so by the time we
    /// drain, the final chunk is already in the buffer.
    public func stopAndDrainPreroll() -> StopResult {
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
            let publish = onLevel
            DispatchQueue.main.async { publish?(0) }
        }
        return lock.withLock {
            prerollChunks.append(contentsOf: drainConverterLocked())
            isStreaming = false
            let drained = Data(prerollChunks.joined())
            let failed = captureFailureReported
            let generation = activeCaptureGeneration
            prerollChunks.removeAll()
            prerollBytes = 0
            captureFailureReported = false
            activeCaptureGeneration = nil
            configurationRestartPending = nil
            return StopResult(
                audio: drained,
                captureFailed: failed,
                generation: generation
            )
        }
    }

    @discardableResult
    public func stop() -> StopResult {
        let wasRunning = isRunning
        if wasRunning {
            engine.inputNode.removeTap(onBus: 0)
            // Measured on this OS: `engine.stop()` blocks until an in-flight tap
            // callback returns. Once it returns, converter access is quiescent and
            // it is safe to send EOS and drain its delayed sample-rate-converter tail.
            engine.stop()
            isRunning = false
        }
        let (tail, wasStreaming, failed, generation) = lock.withLock {
            let tail = drainConverterLocked()
            let wasStreaming = isStreaming
            let failed = captureFailureReported
            let generation = activeCaptureGeneration
            isStreaming = false
            prerollChunks.removeAll()
            prerollBytes = 0
            captureFailureReported = false
            activeCaptureGeneration = nil
            configurationRestartPending = nil
            return (tail, wasStreaming, failed, generation)
        }
        if wasStreaming {
            for chunk in tail { onChunk?(chunk) }
        }
        let publish = onLevel
        if wasRunning || wasStreaming {
            DispatchQueue.main.async { publish?(0) }
        }
        return StopResult(audio: Data(), captureFailed: failed, generation: generation)
    }

    // MARK: - Audio thread

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { deliveredBuffers &+= 1 }
        publishLevel(of: buffer)
        guard let data = convert(buffer), !data.isEmpty else { return }
        routeConvertedChunks([data])
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        // The input device can change under us (headset plugged in); rebuild if so.
        // Serialize the full conversion, not only the pointer lookup: a configuration
        // change or stop may otherwise send EOS to the same converter concurrently.
        var failedGeneration: UInt64?
        let data: Data? = lock.withLock {
            if converterInputFormat != buffer.format,
               !makeConverterLocked(from: buffer.format) {
                if !captureFailureReported {
                    captureFailureReported = true
                    failedGeneration = activeCaptureGeneration
                }
                return nil
            }
            guard let converter else { return nil }

            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: capacity
            ) else {
                return nil
            }

            var consumed = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if status == .error {
                if let conversionError {
                    log.error("resample failed: \(conversionError.localizedDescription)")
                }
                if !captureFailureReported {
                    captureFailureReported = true
                    failedGeneration = activeCaptureGeneration
                }
                return nil
            }
            guard output.frameLength > 0 else { return nil }
            return pcmData(from: output)
        }
        if let failedGeneration { onCaptureFailure?(failedGeneration) }
        return data
    }

    /// Must be called with `lock` held.
    @discardableResult
    private func makeConverterLocked(from format: AVAudioFormat) -> Bool {
        guard format.sampleRate > 0 else { return false }
        converter = AVAudioConverter(from: format, to: targetFormat)
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        converterInputFormat = format
        if converter == nil {
            log.error("could not build converter from \(format) to 24 kHz PCM16")
            return false
        }
        return true
    }

    /// Must be called with `lock` held, after the audio tap has quiesced.
    private func drainConverterLocked() -> [Data] {
        guard let converter else {
            converterInputFormat = nil
            return []
        }

        var chunks: [Data] = []
        for _ in 0..<16 {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: 4096
            ) else {
                break
            }

            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if output.frameLength > 0, let chunk = pcmData(from: output), !chunk.isEmpty {
                chunks.append(chunk)
            }
            if status == .error {
                if let conversionError {
                    log.error("resampler tail flush failed: \(conversionError.localizedDescription)")
                }
                // `stop()` samples this flag after draining, so a failed tail cannot
                // be committed as a healthy-but-silently-truncated utterance.
                captureFailureReported = true
                break
            }
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        self.converter = nil
        converterInputFormat = nil
        return chunks
    }

    private func routeConvertedChunks(_ chunks: [Data]) {
        guard !chunks.isEmpty else { return }
        let streaming = lock.withLock { () -> Bool in
            if isStreaming { return true }
            for chunk in chunks {
                prerollChunks.append(chunk)
                prerollBytes += chunk.count
            }
            while prerollBytes > prerollCapacityBytes, let first = prerollChunks.first {
                prerollChunks.removeFirst()
                prerollBytes -= first.count
            }
            return false
        }

        if streaming {
            for chunk in chunks { onChunk?(chunk) }
        }
    }

    private func reportCaptureFailureOnce() {
        let failedGeneration: UInt64? = lock.withLock {
            guard !captureFailureReported else { return nil }
            captureFailureReported = true
            return activeCaptureGeneration
        }
        if let failedGeneration { onCaptureFailure?(failedGeneration) }
    }

    private func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channel = buffer.int16ChannelData else { return nil }
        return Data(
            bytes: channel[0],
            count: Int(buffer.frameLength) * MemoryLayout<Int16>.size
        )
    }

    private func publishLevel(of buffer: AVAudioPCMBuffer) {
        guard let onLevel, let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let samples = channels[0]
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let sample = samples[index]
            sum += sample * sample
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // Map roughly -50 dBFS…0 dBFS onto 0…1 so quiet speech still moves the meter.
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 50) / 50))
        DispatchQueue.main.async { onLevel(level) }
    }
}
