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

public enum TranscriptionProvider: String, Sendable {
    case openAI = "openai"
    case gemini

    public var requiresSeparatePolish: Bool { self == .openAI }
}

public enum TranscriptionModel: String, CaseIterable, Sendable {
    case geminiLive = "gemini-3.5-transcribe-live"
    case liveTranscribe = "gpt-live-transcribe"
    case transcribe = "gpt-transcribe"

    public var provider: TranscriptionProvider {
        switch self {
        case .geminiLive: .gemini
        case .liveTranscribe, .transcribe: .openAI
        }
    }

    /// Measured on identical audio: the live model emitted 20 deltas before
    /// `input_audio_buffer.commit`, the other zero. Delta *count* is not the
    /// discriminator — both emitted about the same number overall (23 and 24) —
    /// only their timing is. gpt-transcribe holds every one of them until the turn
    /// is committed, by which point the key is already up and there is nothing left
    /// to type into. Retake with `script/ab_transcribe.mjs`.
    /// Gemini also types while speaking, but its stream needs different handling:
    /// its interim is a revisable snapshot rather than an append-only delta, so the
    /// controller types only what two consecutive hypotheses agree on and takes back
    /// the rest with backspaces. See `DictationController.emitPartial`.
    public var supportsLiveTyping: Bool { self == .liveTranscribe || self == .geminiLive }

    /// OpenAI's latency/context knob has no Gemini equivalent.
    public var supportsTranscriptionDelay: Bool { self == .liveTranscribe }
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

    public var transcriptionModel: TranscriptionModel {
        store.string(forKey: "transcriptionModel")
            .flatMap(TranscriptionModel.init) ?? .geminiLive
    }
    public var transcriptionDelay: TranscriptionDelay {
        store.string(forKey: "transcriptionDelay").flatMap(TranscriptionDelay.init) ?? .low
    }
    public var vocabularyTerms: [String] { [] }
}
