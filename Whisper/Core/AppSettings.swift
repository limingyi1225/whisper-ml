import DictationKit
import Foundation

// ConnectionMode, TranscriptionModel and TranscriptionDelay now live in
// DictationKit, because ServiceRoute and RealtimeClient are the code that acts
// on them. What stays here is everything the package has no business holding:
// the display copy, which is localised, and Identifiable, which exists for
// SwiftUI.

extension ConnectionMode: @retroactive Identifiable {
    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .direct: return "直连"
        // Not "大陆模式": the point is that the device holds no OpenAI key, which is
        // useful anywhere. Naming it after one reason to want it made people in the US
        // assume it did not apply to them.
        case .relay: return "代理模式"
        }
    }
}

/// Which physical key must be held down to dictate.
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

    var displayName: String { rawValue }
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

    var connectionMode: ConnectionMode {
        didSet { store.set(connectionMode.rawValue, forKey: Key.connectionMode) }
    }
    var triggerKey: TriggerKey { didSet { store.set(triggerKey.rawValue, forKey: Key.triggerKey) } }
    var transcriptionDelay: TranscriptionDelay { didSet { store.set(transcriptionDelay.rawValue, forKey: Key.transcriptionDelay) } }
    var transcriptionModel: TranscriptionModel { didSet { store.set(transcriptionModel.rawValue, forKey: Key.transcriptionModel) } }

    /// There is no separate "output mode" choice: picking the model already decides
    /// this. A streaming model types as you speak; the others cannot return a word
    /// before you let go, so they paste once at the end.
    var typesWhileSpeaking: Bool { transcriptionModel.supportsLiveTyping }
    /// Clean up filler words and false starts after the key is released.
    var polishEnabled: Bool { didSet { store.set(polishEnabled, forKey: Key.polishEnabled) } }
    /// Drop the full stop the models like to end every utterance with. Done in code
    /// rather than by prompting: the realtime transcriber adds one too, so a prompt
    /// to the cleanup model alone could never cover both paths.
    var stripTrailingPeriod: Bool { didSet { store.set(stripTrailingPeriod, forKey: Key.stripTrailingPeriod) } }
    /// Rewrite traditional Chinese as simplified. The transcriber returns 繁体 for
    /// some of the same speech it usually returns 简体 for. Done in code, on the way
    /// in, rather than by asking the cleanup model: a whole sentence of 繁体 differs
    /// from its cleaned version at character zero, and `reconcile` would then rewrite
    /// every such sentence in full — the exact flash the whitespace rule exists to avoid.
    var simplifyChinese: Bool { didSet { store.set(simplifyChinese, forKey: Key.simplifyChinese) } }
    /// Proper nouns the transcriber keeps mis-hearing — names, products, jargon — one
    /// per line, spelled the way the user wants them. Goes to both sides: the
    /// transcription session's `keywords`, which biases recognition itself, and the
    /// cleanup model, which repairs whatever got through. The second is a fallback
    /// now rather than the primary — see `RealtimeClient.sendSessionUpdate` — and it
    /// stays because bias is not a guarantee.
    var vocabulary: String { didSet { store.set(vocabulary, forKey: Key.vocabulary) } }

    /// Names the people using this app say constantly and the transcriber keeps
    /// spelling as some other homophone. They ride along on every cleanup request and
    /// are deliberately absent from Settings: the box is for words the user thinks to
    /// add, and nobody thinks to add the spelling of their own name until they have
    /// already seen it come out wrong a dozen times.
    static let builtInVocabulary = ["李铭一", "赵芸溪"]

    /// The vocabulary as the cleanup pass sees it.
    var vocabularyTerms: [String] { Self.vocabularyTerms(userList: vocabulary) }

    /// Built-ins first, then the user's own list minus any line that just repeats one
    /// of them. The user's cap applies to the user's lines only — a built-in must not
    /// be able to push out a term someone typed deliberately.
    static func vocabularyTerms(userList raw: String) -> [String] {
        builtInVocabulary + parseVocabulary(raw).filter { !builtInVocabulary.contains($0) }
    }

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

    /// Whether the user has ever picked a connection mode, as opposed to living with
    /// the default. The absence of the key is the only honest test for it.
    ///
    /// A personalised build wants to come up in 代理模式 on a fresh Mac, but "fresh"
    /// cannot be inferred from a credential being absent: someone using 直连 with their
    /// own API key has no relay token either, and flipping *them* to relay would reroute
    /// their audio and their billing without being asked.
    static var connectionModeWasChosen: Bool {
        UserDefaults.standard.string(forKey: Key.connectionMode) != nil
    }

    private enum Key {
        static let connectionMode = "connectionMode"
        static let triggerKey = "triggerKey"
        static let transcriptionDelay = "transcriptionDelay"
        static let transcriptionModel = "transcriptionModel"
        static let polishEnabled = "polishEnabled"
        static let stripTrailingPeriod = "stripTrailingPeriod"
        static let simplifyChinese = "simplifyChinese"
        static let vocabulary = "vocabulary"
    }

    private init() {
        let mode = store.string(forKey: Key.connectionMode)
        connectionMode = mode.flatMap(ConnectionMode.init(rawValue:)) ?? .direct
        let trigger = store.string(forKey: Key.triggerKey)
        triggerKey = trigger.flatMap(TriggerKey.init(rawValue:)) ?? .rightCommand
        let delay = store.string(forKey: Key.transcriptionDelay)
        transcriptionDelay = delay.flatMap(TranscriptionDelay.init(rawValue:)) ?? .low
        let model = store.string(forKey: Key.transcriptionModel)
        transcriptionModel = model.flatMap(TranscriptionModel.init(rawValue:)) ?? .liveTranscribe
        polishEnabled = store.object(forKey: Key.polishEnabled) as? Bool ?? true
        stripTrailingPeriod = store.bool(forKey: Key.stripTrailingPeriod)
        simplifyChinese = store.object(forKey: Key.simplifyChinese) as? Bool ?? true
        vocabulary = store.string(forKey: Key.vocabulary) ?? ""
    }
}
