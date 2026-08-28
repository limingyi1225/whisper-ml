import DictationKit
import Foundation

// TranscriptionModel and TranscriptionDelay live in DictationKit, because
// ServiceRoute and RealtimeClient are the code that acts on them. What stays here is everything the package has no business holding:
// the display copy, which is localised, and Identifiable, which exists for
// SwiftUI.

enum TriggerKey: String, CaseIterable, Identifiable {
    case rightCommand, leftCommand, rightOption, leftOption

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightCommand: return "右 Command ⌘"
        case .leftCommand: return "左 Command ⌘"
        case .rightOption: return "右 Option ⌥"
        case .leftOption: return "左 Option ⌥"
        }
    }

    /// Virtual keycode reported by `flagsChanged` events.
    var keyCode: Int64 {
        switch self {
        case .rightCommand: return 54
        case .leftCommand: return 55
        case .leftOption: return 58
        case .rightOption: return 61
        }
    }

    /// Device-dependent modifier bit (IOKit `NX_DEVICE…KEYMASK`) that is set while
    /// this specific physical key is down. `flagsChanged` alone cannot tell left
    /// from right, so we test these instead.
    var deviceMask: UInt64 {
        switch self {
        case .leftCommand: return 0x0000_0008
        case .rightCommand: return 0x0000_0010
        case .leftOption: return 0x0000_0020
        case .rightOption: return 0x0000_0040
        }
    }

    /// Modifier bits that, if present, mean the user is typing a shortcut rather
    /// than dictating — used to bail out of an armed trigger.
    var foreignModifierMask: UInt64 {
        // maskShift | maskControl | maskAlternate | maskCommand, minus our own.
        let all: UInt64 = 0x0002_0000 | 0x0004_0000 | 0x0008_0000 | 0x0010_0000
        switch self {
        case .rightCommand, .leftCommand: return all & ~0x0010_0000
        case .rightOption, .leftOption: return all & ~0x0008_0000
        }
    }
}

extension TranscriptionModel: @retroactive Identifiable {
    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .geminiLive: "Gemini 3.5 Transcribe Live"
        case .liveTranscribe: "OpenAI Live（备用）"
        case .transcribe: "OpenAI Transcribe（备用）"
        }
    }
}

extension TranscriptionDelay: @retroactive Identifiable {
    public var id: String { rawValue }

    /// Measured time from audio start to the first delta on this machine's connection.
    var displayName: String {
        switch self {
        case .minimal: return "最短 · 首字约 0.7 秒"
        case .low: return "短 · 首字约 0.8 秒"
        case .medium: return "中 · 首字约 1.3 秒"
        case .high: return "长 · 首字约 1.9 秒"
        case .xhigh: return "最长"
        }
    }
}


@Observable
final class AppSettings: DictationSettingsProviding {
    static let shared = AppSettings()

    private let store = UserDefaults.standard

    var triggerKey: TriggerKey { didSet { store.set(triggerKey.rawValue, forKey: Key.triggerKey) } }
    var transcriptionDelay: TranscriptionDelay { didSet { store.set(transcriptionDelay.rawValue, forKey: Key.transcriptionDelay) } }
    var transcriptionModel: TranscriptionModel { didSet { store.set(transcriptionModel.rawValue, forKey: Key.transcriptionModel) } }

    /// There is no separate "output mode" choice: picking the model already decides
    /// this. A streaming model types as you speak; the others cannot return a word
    /// before you let go, so they paste once at the end.
    var typesWhileSpeaking: Bool { transcriptionModel.supportsLiveTyping }
    /// Legacy preference retained so older installed builds and Wink can still read
    /// their previous setting. The current Whisper UI keeps cleanup on permanently:
    /// Gemini does it in SMART mode and OpenAI fallback uses TranscriptPolisher.
    var polishEnabled: Bool { didSet { store.set(polishEnabled, forKey: Key.polishEnabled) } }
    /// Drop the full stop the models like to end every utterance with. Done in code
    /// rather than by prompting: the realtime transcriber adds one too, so a prompt
    /// to the cleanup model alone could never cover both paths.
    var stripTrailingPeriod: Bool { didSet { store.set(stripTrailingPeriod, forKey: Key.stripTrailingPeriod) } }
    /// Proper nouns the transcriber keeps mis-hearing — names, products, jargon — one
    /// per line, spelled the way the user wants them. Goes to both sides: the
    /// transcription session's `keywords`, which biases recognition itself, and the
    /// cleanup model, which repairs whatever got through. The second is a fallback
    /// now rather than the primary — see `RealtimeClient.sendSessionUpdate` — and it
    /// stays because bias is not a guarantee.
    ///
    /// This box is the whole list. Nothing is added behind it, because biasing has a
    /// cost the user has to be able to pay back: `customVocabulary` raises a term's
    /// prior, so a noisy or clipped stretch of audio that merely sounds close gets
    /// pulled onto it, and neither Gemini nor OpenAI exposes a strength knob to soften
    /// that. A term the user can see is a term they can delete when it starts firing
    /// on words they never said; a hidden one leaves them editing a box that is not
    /// the thing misbehaving.
    var vocabulary: String { didSet { store.set(vocabulary, forKey: Key.vocabulary) } }

    /// Seeded into the box once, not forced on every launch — see
    /// `seedVocabularyIfNeeded`. Nobody thinks to add the spelling of their own name
    /// until they have already seen it come out wrong a dozen times, so the first
    /// launch supplies it; from then on it is an ordinary line like any other.
    static let seededVocabulary = ["李铭一"]

    /// The vocabulary as the transcription session and the cleanup pass see it.
    var vocabularyTerms: [String] { Self.parseVocabulary(vocabulary) }

    /// One term per line; blank lines and duplicates dropped, order preserved.
    ///
    /// Both caps exist because this list rides along in *every* cleanup request:
    /// pasting an essay into the box would slow down every sentence the user speaks.
    /// Over-long lines are dropped rather than truncated — a 40+ character "term" is
    /// prose someone typed into the wrong box, and half of it is not a spelling
    /// anybody wants enforced. The settings editor mirrors these checks before
    /// saving; the parser remains the final guard for older persisted values.
    static let vocabularyTermLimit = 100
    static let vocabularyTermLengthLimit = 40

    static func parseVocabulary(_ raw: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let term = line.trimmingCharacters(in: .whitespaces)
            // Measured in UTF-16 units, not Characters, because the relay enforces the
            // same cap in JavaScript — where `"𠮷".length` is 2. A name in CJK
            // extension B counts as one Character here and two there, so a list this
            // side considers legal could be rejected the other side. That rejection is
            // not a dropped word: `session.update` fails as a whole, and dictation
            // stops working until the box is edited.
            guard !term.isEmpty,
                  term.utf16.count <= vocabularyTermLengthLimit,
                  // `<` and `>` are documented as invalid inside a transcription
                  // keyword, and the cleanup pass wraps the transcript in
                  // `<transcript>` — a term carrying either would be arguing with
                  // both consumers of this list at once.
                  !term.contains(where: { $0 == "<" || $0 == ">" })
            else { continue }
            guard seen.insert(term).inserted else { continue }
            terms.append(term)
            if terms.count == vocabularyTermLimit { break }
        }
        return terms
    }

    private enum Key {
        static let triggerKey = "triggerKey"
        static let transcriptionDelay = "transcriptionDelay"
        static let transcriptionModel = "transcriptionModel"
        static let polishEnabled = "polishEnabled"
        static let adoptedGeminiDefault = "adoptedGeminiDefault"
        static let seededVocabulary = "seededVocabulary"
        static let stripTrailingPeriod = "stripTrailingPeriod"
        static let vocabulary = "vocabulary"
    }

    private init() {
        let trigger = store.string(forKey: Key.triggerKey)
        triggerKey = trigger.flatMap(TriggerKey.init(rawValue:)) ?? .rightCommand
        let delay = store.string(forKey: Key.transcriptionDelay)
        transcriptionDelay = delay.flatMap(TranscriptionDelay.init(rawValue:)) ?? .low
        let model = store.string(forKey: Key.transcriptionModel)
        transcriptionModel = model.flatMap(TranscriptionModel.init(rawValue:)) ?? .geminiLive
        polishEnabled = store.object(forKey: Key.polishEnabled) as? Bool ?? true
        stripTrailingPeriod = store.bool(forKey: Key.stripTrailingPeriod)
        vocabulary = store.string(forKey: Key.vocabulary) ?? ""
        adoptGeminiDefaultIfNeeded()
        seedVocabularyIfNeeded()
    }

    /// Moves the formerly built-in names into the box, once. An install that already
    /// lists a seeded name keeps its own line rather than gaining a second copy, and
    /// an install that deletes one afterwards stays deleted — that is the entire point
    /// of the move, so the flag is written whether or not anything was appended.
    ///
    private func seedVocabularyIfNeeded() {
        guard !store.bool(forKey: Key.seededVocabulary) else { return }
        store.set(true, forKey: Key.seededVocabulary)
        guard let seeded = Self.vocabularySeeded(into: vocabulary) else { return }
        vocabulary = seeded
    }

    /// The box with the seeded names appended, or `nil` when it already covers them.
    ///
    /// Appends to the stored text rather than rewriting it from `parseVocabulary`:
    /// re-serialising the parsed list would quietly delete any line the parser rejects,
    /// and a launch that was only supposed to add a name is the wrong moment to throw
    /// away something the user typed.
    static func vocabularySeeded(into raw: String) -> String? {
        let existing = parseVocabulary(raw)
        let missing = seededVocabulary.filter { !existing.contains($0) }
        guard !missing.isEmpty else { return nil }
        return ([raw] + missing).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// One intentional migration: an existing install moves to Gemini once, but
    /// selecting an OpenAI fallback afterwards remains sticky on every later launch.
    private func adoptGeminiDefaultIfNeeded() {
        guard !store.bool(forKey: Key.adoptedGeminiDefault) else { return }
        transcriptionModel = .geminiLive
        polishEnabled = true
        store.set(true, forKey: Key.adoptedGeminiDefault)
    }
}
