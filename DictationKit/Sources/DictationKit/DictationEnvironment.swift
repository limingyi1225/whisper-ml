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

/// No selectable model uses `.openAI` any more. The provider, `TranscriptPolisher`, the
/// polish path and the relay's OpenAI bridge stay only to keep the change that removed
/// the models small; they are to be removed together in a follow-up.
public enum TranscriptionProvider: String, Sendable {
    case openAI = "openai"
    case gemini
    case soniox

    /// Whether a finished transcript takes the separate text pass before it is delivered.
    ///
    /// Gemini SMART cleans up inside the transcription turn, so nothing is left to do.
    /// Soniox does no cleanup at all and is deliberately left that way: it is the route
    /// chosen for speed, and the text pass costs about a second after the key is
    /// released — more than Soniox saves. Its sentences are delivered as spoken, filler
    /// words included. Only the OpenAI route pays for the pass.
    public var requiresSeparatePolish: Bool { self == .openAI }

    /// Whether a turn's `item_id` comes from the provider or is made up by the relay.
    ///
    /// OpenAI names every event with the item it belongs to, so a turn that was given
    /// up on can be retired by id and the socket kept. Gemini and Soniox results carry
    /// no turn identity at all — the relay synthesizes one for the app's benefit — so
    /// once audio has reached them, only a fresh session can prove that a late result
    /// is not from the abandoned sentence.
    public var identifiesTurnsItself: Bool { self == .openAI }

    /// Whether the final transcript arrives exactly as the interims were written.
    ///
    /// Soniox delivers the sentence as spoken, with no cleanup inside the turn or after
    /// it, so its final can carry the interims' own artifacts — a stray space after `。`
    /// is the measured one. Gemini SMART's final has already been cleaned, and is
    /// delivered untouched.
    public var finalIsUncleaned: Bool { self == .soniox }
}

public enum TranscriptionModel: String, CaseIterable, Sendable {
    case geminiLive = "gemini-3.5-transcribe-live"
    case sonioxLive = "stt-rt-v6"

    public var provider: TranscriptionProvider {
        switch self {
        case .geminiLive: .gemini
        case .sonioxLive: .soniox
        }
    }

    /// Whether the model returns words while the key is still down.
    ///
    /// Both models do. Each interim is a snapshot of the whole sentence so far rather
    /// than an append-only delta: Gemini may rewrite what it already sent, and Soniox
    /// sends the tokens it has marked final followed by a tail it may still revise. The
    /// controller therefore types only what two consecutive snapshots agree on and takes
    /// back the rest with backspaces. See `DictationController.emitPartial`.
    ///
    /// The property stays for a model that cannot: one that holds every word until the
    /// turn is committed has nothing to type into by then, and is pasted once at the end.
    public var supportsLiveTyping: Bool { true }
}

/// How much audio the model hears before it commits to words.
///
/// No remaining model reads this. It stays, with the protocol requirement below, only
/// to keep the change that removed the OpenAI models small, and goes with the rest of
/// the OpenAI route in a follow-up.
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
