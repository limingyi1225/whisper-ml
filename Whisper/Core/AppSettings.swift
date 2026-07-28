import Foundation

/// Where OpenAI traffic leaves the app.
///
/// Relay mode is deliberately explicit rather than an automatic fallback. Switching a
/// live Realtime session after audio and partial text have already crossed one route can
/// replay or duplicate an utterance; the controller therefore reconnects only at an idle
/// boundary when this setting changes.
enum ConnectionMode: String, CaseIterable, Identifiable {
    case direct
    case relay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .direct: return "直连"
        // Not "大陆模式": the point is that the device holds no OpenAI key, which is
        // useful anywhere. Naming it after one reason to want it made people in the US
        // assume it did not apply to them.
        case .relay: return "代理模式"
        }
    }

    var summary: String {
        switch self {
        case .direct:
            return "Mac 使用钥匙串里的 OpenAI API Key 直接连接。"
        case .relay:
            return "Mac 只连接你的服务器，本机不保存 OpenAI API Key；无 VPN 时也能用。"
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

enum TranscriptionModel: String, CaseIterable, Identifiable {
    case realtimeWhisper = "gpt-realtime-whisper"
    case transcribe = "gpt-4o-transcribe"
    case miniTranscribe = "gpt-4o-mini-transcribe"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realtimeWhisper: return "gpt-realtime-whisper"
        case .transcribe: return "gpt-4o-transcribe"
        case .miniTranscribe: return "gpt-4o-mini-transcribe"
        }
    }

    /// Measured on identical audio: the realtime model emitted 36 deltas before
    /// `input_audio_buffer.commit`; both gpt-4o-transcribe models emitted zero and
    /// delivered everything afterwards. Live typing is therefore impossible on them.
    var supportsLiveTyping: Bool { self == .realtimeWhisper }

    var summary: String {
        switch self {
        case .realtimeWhisper: return "唯一能边说边出字的模型，也最贵"
        case .transcribe: return "更便宜，但只能松手后一次性出字"
        case .miniTranscribe: return "最便宜，只能松手后一次性出字"
        }
    }
}

/// How much audio the model hears before it commits to words.
enum TranscriptionDelay: String, CaseIterable, Identifiable {
    case minimal, low, medium, high, xhigh

    var id: String { rawValue }

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
final class AppSettings {
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
    /// per line, spelled the way the user wants them. Handed to the cleanup model,
    /// which is the only channel available: `gpt-realtime-whisper` rejects `prompt`,
    /// the one vocabulary-bias slot the transcription side has.
    var vocabulary: String { didSet { store.set(vocabulary, forKey: Key.vocabulary) } }

    /// The vocabulary as the cleanup pass sees it.
    var vocabularyTerms: [String] { Self.parseVocabulary(vocabulary) }

    /// One term per line; blank lines and duplicates dropped, order preserved.
    ///
    /// Both caps exist because this list rides along in *every* cleanup request:
    /// pasting an essay into the box would slow down every sentence the user speaks.
    /// Over-long lines are dropped rather than truncated — a 40+ character "term" is
    /// prose someone typed into the wrong box, and half of it is not a spelling
    /// anybody wants enforced. The settings pane shows the accepted count so a
    /// dropped line is visible rather than silent.
    static let vocabularyTermLimit = 100
    static let vocabularyTermLengthLimit = 40

    static func parseVocabulary(_ raw: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let term = line.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, term.count <= vocabularyTermLengthLimit else { continue }
            guard seen.insert(term).inserted else { continue }
            terms.append(term)
            if terms.count == vocabularyTermLimit { break }
        }
        return terms
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
        transcriptionModel = model.flatMap(TranscriptionModel.init(rawValue:)) ?? .realtimeWhisper
        polishEnabled = store.object(forKey: Key.polishEnabled) as? Bool ?? true
        stripTrailingPeriod = store.bool(forKey: Key.stripTrailingPeriod)
        simplifyChinese = store.object(forKey: Key.simplifyChinese) as? Bool ?? true
        vocabulary = store.string(forKey: Key.vocabulary) ?? ""
    }
}
