import Foundation

// The settings these files need, expressed as something the package can own.
//
// Before the split they read the app's `AppSettings.shared` directly. That
// cannot survive a package boundary — it would point from the library back at
// the app — so the dependency is inverted: the package declares what it needs,
// and the host supplies it at launch.
//
// The enums live here rather than in the app because `ServiceRoute` and
// `RealtimeClient` are the code that acts on them. Their display strings stay
// in the app, as extensions: the package has no business holding UI copy, and
// keeping it out means no localisation lives down here.

/// Where OpenAI traffic leaves the app.
///
/// Relay mode is deliberately explicit rather than an automatic fallback.
/// Switching a live Realtime session after audio and partial text have already
/// crossed one route can replay or duplicate an utterance; the controller
/// therefore reconnects only at an idle boundary when this setting changes.
public enum ConnectionMode: String, CaseIterable, Sendable {
    case direct
    case relay
}

public enum TranscriptionModel: String, CaseIterable, Sendable {
    case realtimeWhisper = "gpt-realtime-whisper"
    case transcribe = "gpt-4o-transcribe"
    case miniTranscribe = "gpt-4o-mini-transcribe"

    /// Measured on identical audio: the realtime model emitted 36 deltas before
    /// `input_audio_buffer.commit`; both gpt-4o-transcribe models emitted zero
    /// and delivered everything afterwards. Live typing is therefore impossible
    /// on them.
    public var supportsLiveTyping: Bool { self == .realtimeWhisper }
}

/// How much audio the model hears before it commits to words.
public enum TranscriptionDelay: String, CaseIterable, Sendable {
    case minimal, low, medium, high, xhigh
}

/// What the dictation stack reads out of its host's settings.
///
/// Read-only on purpose. The package never writes a preference — deciding what
/// a setting means, and when it may change, belongs to whoever owns the UI.
public protocol DictationSettingsProviding: AnyObject {
    var connectionMode: ConnectionMode { get }
    var transcriptionModel: TranscriptionModel { get }
    var transcriptionDelay: TranscriptionDelay { get }
    /// Terms to bias the cleanup model towards. Already parsed and capped.
    var vocabularyTerms: [String] { get }
}

/// The host's settings, injected once at launch.
public enum DictationEnvironment {
    /// Defaults to reading `UserDefaults.standard` with the same keys and
    /// defaults the app uses, so forgetting to inject degrades to "behaves as
    /// if nothing was configured" rather than a crash on the first utterance.
    public static var settings: any DictationSettingsProviding = FallbackSettings()
}

/// Stand-in used until a host injects its own.
public final class FallbackSettings: DictationSettingsProviding {
    private let store = UserDefaults.standard

    public init() {}

    public var connectionMode: ConnectionMode {
        store.string(forKey: "connectionMode").flatMap(ConnectionMode.init) ?? .direct
    }
    public var transcriptionModel: TranscriptionModel {
        store.string(forKey: "transcriptionModel")
            .flatMap(TranscriptionModel.init) ?? .realtimeWhisper
    }
    public var transcriptionDelay: TranscriptionDelay {
        store.string(forKey: "transcriptionDelay").flatMap(TranscriptionDelay.init) ?? .low
    }
    public var vocabularyTerms: [String] { [] }
}
