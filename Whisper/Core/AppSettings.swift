import DictationKit
import Foundation

// TranscriptionModel lives in DictationKit, because ServiceRoute and RealtimeClient
// are the code that acts on it. What stays here is everything the package has no
// business holding: the display copy, which is localised, and Identifiable, which
// exists for SwiftUI.

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
        case .sonioxLive: "Soniox v6"
        }
    }
}


@Observable
final class AppSettings: DictationSettingsProviding {
    static let shared = AppSettings()

    private let store = UserDefaults.standard

    var triggerKey: TriggerKey { didSet { store.set(triggerKey.rawValue, forKey: Key.triggerKey) } }
    /// No remaining model reads this and nothing in the UI sets it. It stays because
    /// `DictationSettingsProviding` still requires it, and goes when the OpenAI route is
    /// removed from DictationKit in a follow-up.
    var transcriptionDelay: TranscriptionDelay { didSet { store.set(transcriptionDelay.rawValue, forKey: Key.transcriptionDelay) } }
    var transcriptionModel: TranscriptionModel { didSet { store.set(transcriptionModel.rawValue, forKey: Key.transcriptionModel) } }

    /// There is no separate "output mode" choice: picking the model already decides
    /// this. Both current models stream, so both type as you speak; a model that could
    /// not return a word before you let go would paste once at the end.
    var typesWhileSpeaking: Bool { transcriptionModel.supportsLiveTyping }
    /// Legacy preference. Nothing in Whisper reads it and there is no switch for it:
    /// Gemini cleans up inside its SMART turn and Soniox is delivered as spoken. The
    /// stored value is kept for now and goes with the OpenAI route in a follow-up.
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
    /// This box is the whole list — nothing rides behind it, and the app never writes
    /// into it on its own initiative. Biasing is not free: `customVocabulary` raises a
    /// term's prior, so a noisy or clipped stretch of audio that merely sounds close
    /// gets pulled onto it, and Gemini exposes no strength knob to soften that. Only a
    /// term the user typed is worth that cost, and only a term they can see is one they
    /// can delete once it starts firing on words nobody said. An empty box biases
    /// nothing.
    var vocabulary: String { didSet { store.set(vocabulary, forKey: Key.vocabulary) } }

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
        static let stripTrailingPeriod = "stripTrailingPeriod"
        static let vocabulary = "vocabulary"
    }

    /// What a stored model name means today. A name this build does not know — one from
    /// a newer build, or one of the removed OpenAI models — is Gemini, not an error.
    static func storedTranscriptionModel(_ raw: String?) -> TranscriptionModel {
        raw.flatMap(TranscriptionModel.init(rawValue:)) ?? .geminiLive
    }

    private init() {
        let trigger = store.string(forKey: Key.triggerKey)
        triggerKey = trigger.flatMap(TriggerKey.init(rawValue:)) ?? .rightCommand
        let delay = store.string(forKey: Key.transcriptionDelay)
        transcriptionDelay = delay.flatMap(TranscriptionDelay.init(rawValue:)) ?? .low
        transcriptionModel = Self.storedTranscriptionModel(
            store.string(forKey: Key.transcriptionModel)
        )
        polishEnabled = store.object(forKey: Key.polishEnabled) as? Bool ?? true
        stripTrailingPeriod = store.bool(forKey: Key.stripTrailingPeriod)
        vocabulary = store.string(forKey: Key.vocabulary) ?? ""
        adoptGeminiDefaultIfNeeded()
    }

    /// One intentional migration: an existing install moves to Gemini once; whatever
    /// model is chosen afterwards remains sticky on every later launch.
    ///
    /// The OpenAI models that could once be chosen here are gone. A stored
    /// `gpt-live-transcribe` or `gpt-transcribe` no longer parses, so `init` has already
    /// resolved it to Gemini before this runs — see `storedTranscriptionModel`.
    private func adoptGeminiDefaultIfNeeded() {
        guard !store.bool(forKey: Key.adoptedGeminiDefault) else { return }
        transcriptionModel = .geminiLive
        polishEnabled = true
        store.set(true, forKey: Key.adoptedGeminiDefault)
    }
}
