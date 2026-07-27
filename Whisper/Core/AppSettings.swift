import Foundation

/// Which physical key must be held down to dictate.
enum TriggerKey: String, CaseIterable, Identifiable {
    case rightCommand, leftCommand, rightOption, leftOption, fn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightCommand: return "右 Command ⌘"
        case .leftCommand: return "左 Command ⌘"
        case .rightOption: return "右 Option ⌥"
        case .leftOption: return "左 Option ⌥"
        case .fn: return "Fn / 🌐 地球键"
        }
    }

    /// Virtual keycode reported by `flagsChanged` events.
    var keyCode: Int64 {
        switch self {
        case .rightCommand: return 54
        case .leftCommand: return 55
        case .leftOption: return 58
        case .rightOption: return 61
        case .fn: return 63
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
        case .fn: return 0x0080_0000  // NX_SECONDARYFNMASK
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
        case .fn: return all
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

/// How long the trigger key must be held before it counts as dictation rather than an
/// ordinary modifier press. Exposed as named tiers — the exact millisecond value is an
/// implementation detail nobody should have to reason about.
enum HoldThreshold: String, CaseIterable, Identifiable {
    case quick, standard, deliberate

    var id: String { rawValue }

    var milliseconds: Double {
        switch self {
        case .quick: return 200
        case .standard: return 300
        case .deliberate: return 500
        }
    }

    var displayName: String {
        switch self {
        case .quick: return "灵敏 · 按下几乎立刻开始录"
        case .standard: return "标准"
        case .deliberate: return "沉稳 · 几乎不会误触发"
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

    var triggerKey: TriggerKey { didSet { store.set(triggerKey.rawValue, forKey: Key.triggerKey) } }
    var holdThreshold: HoldThreshold { didSet { store.set(holdThreshold.rawValue, forKey: Key.holdThreshold) } }
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

    private enum Key {
        static let triggerKey = "triggerKey"
        static let holdThreshold = "holdThreshold"
        static let transcriptionDelay = "transcriptionDelay"
        static let transcriptionModel = "transcriptionModel"
        static let polishEnabled = "polishEnabled"
        static let stripTrailingPeriod = "stripTrailingPeriod"
    }

    private init() {
        let trigger = store.string(forKey: Key.triggerKey)
        triggerKey = trigger.flatMap(TriggerKey.init(rawValue:)) ?? .rightCommand
        let hold = store.string(forKey: Key.holdThreshold)
        holdThreshold = hold.flatMap(HoldThreshold.init(rawValue:)) ?? .standard
        let delay = store.string(forKey: Key.transcriptionDelay)
        transcriptionDelay = delay.flatMap(TranscriptionDelay.init(rawValue:)) ?? .low
        let model = store.string(forKey: Key.transcriptionModel)
        transcriptionModel = model.flatMap(TranscriptionModel.init(rawValue:)) ?? .realtimeWhisper
        polishEnabled = store.object(forKey: Key.polishEnabled) as? Bool ?? true
        stripTrailingPeriod = store.bool(forKey: Key.stripTrailingPeriod)
    }
}
