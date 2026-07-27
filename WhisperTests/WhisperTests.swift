import Testing
@testable import Whisper

// MARK: - Transcript normalization

@Suite struct NormalizeLeadingSpaceTests {
    @Test func latinKeepsExactlyOneSpace() {
        #expect(DictationController.normalizeLeadingSpace(" hello") == " hello")
        #expect(DictationController.normalizeLeadingSpace("   hello") == " hello")
        #expect(DictationController.normalizeLeadingSpace(" 42度") == " 42度")
    }

    @Test func cjkDropsTheSpace() {
        #expect(DictationController.normalizeLeadingSpace(" 你好") == "你好")
        #expect(DictationController.normalizeLeadingSpace("\t你好") == "你好")
        #expect(DictationController.normalizeLeadingSpace(" ！") == "！")
    }

    @Test func noLeadingSpaceIsUntouched() {
        #expect(DictationController.normalizeLeadingSpace("hello") == "hello")
        #expect(DictationController.normalizeLeadingSpace("你好") == "你好")
        #expect(DictationController.normalizeLeadingSpace("") == "")
    }

    @Test func whitespaceOnlyBecomesEmpty() {
        #expect(DictationController.normalizeLeadingSpace("   ") == "")
    }
}

@Suite struct CommonPrefixLengthTests {
    @Test func countsMatchingGraphemes() {
        #expect(DictationController.commonPrefixLength("abc", "abd") == 2)
        #expect(DictationController.commonPrefixLength("你好吗", "你好啊") == 2)
        #expect(DictationController.commonPrefixLength("same", "same") == 4)
    }

    @Test func emptyAndDisjointAreZero() {
        #expect(DictationController.commonPrefixLength("", "x") == 0)
        #expect(DictationController.commonPrefixLength("a", "b") == 0)
    }

    @Test func multiScalarGraphemesCountAsOne() {
        // 👨‍👩‍👧 is one grapheme built from several scalars; a partial match inside
        // it must not count. deleteBackward deletes per grapheme, so this
        // count is what keeps the backspace count aligned with what the user sees.
        #expect(DictationController.commonPrefixLength("👨‍👩‍👧a", "👨‍👩‍👧b") == 1)
    }
}

@Suite struct IgnoringWhitespaceTests {
    @Test func stripsAllWhitespaceKinds() {
        #expect("a b\tc\nd".ignoringWhitespace == "abcd")
        #expect("你好 世界".ignoringWhitespace == "你好世界")
        #expect("   ".ignoringWhitespace == "")
    }
}

@Suite struct FriendlyMessageTests {
    @Test func translatesKnownServerErrors() {
        #expect(DictationController.friendlyMessage("input buffer too small for commit")
            == "录音太短，没有听到内容")
        #expect(DictationController.friendlyMessage("Incorrect API key provided")
            == "API Key 无效或没有权限")
        #expect(DictationController.friendlyMessage("You exceeded your current quota")
            == "OpenAI 额度不足，去检查账单")
        #expect(DictationController.friendlyMessage("Rate limit reached")
            == "请求太频繁，稍等几秒再试")
    }

    @Test func chineseMessagesPassThroughUntranslated() {
        // Our own messages can legitimately contain English keywords
        // ("还没有设置 API Key") — keyword matching must not fire on them.
        #expect(DictationController.friendlyMessage("还没有设置 API Key") == "还没有设置 API Key")
        #expect(DictationController.friendlyMessage("连接中断：quota") == "连接中断：quota")
    }

    @Test func unknownEnglishPassesThrough() {
        #expect(DictationController.friendlyMessage("something unexpected") == "something unexpected")
    }
}

// MARK: - Keyboard event chunking

@Suite struct ChunkedUnicodeTests {
    @Test func shortRunsPassThroughWhole() {
        let units = Array("hello".utf16)
        #expect(TextInjector.chunked(units) == [units])
        let sixteen = Array(String(repeating: "x", count: 16).utf16)
        #expect(TextInjector.chunked(sixteen) == [sixteen])
    }

    @Test func longRunsSplitWithoutLosingUnits() {
        let units = Array(String(repeating: "水", count: 50).utf16)
        let chunks = TextInjector.chunked(units)
        #expect(chunks.flatMap(\.self) == units)
        #expect(chunks.allSatisfy { $0.count <= 16 && !$0.isEmpty })
    }

    @Test func neverSplitsASurrogatePair() {
        // "𝕏" is a surrogate pair. Place its high surrogate exactly at the
        // 16-unit boundary so a naive split would separate the pair.
        let text = String(repeating: "a", count: 15) + String(repeating: "𝕏", count: 3)
        let units = Array(text.utf16)
        let chunks = TextInjector.chunked(units)
        #expect(chunks.flatMap(\.self) == units)
        for chunk in chunks {
            #expect(!TextInjector.isHighSurrogate(chunk.last!))
        }
    }
}

// MARK: - Realtime protocol plumbing

@Suite struct TurnSequenceTests {
    @Test func parsesTurnScopedEventIDs() {
        let client = RealtimeClient()
        #expect(client.turnSequence(fromClientEventID: "whisper-turn-3-17") == 3)
        #expect(client.turnSequence(fromClientEventID: "whisper-turn-12-1") == 12)
    }

    @Test func rejectsEverythingElse() {
        let client = RealtimeClient()
        // Session-scoped ids and foreign/malformed ids must not be attributed
        // to any turn — a mis-parse here aborts the wrong dictation.
        #expect(client.turnSequence(fromClientEventID: "whisper-session-4") == nil)
        #expect(client.turnSequence(fromClientEventID: "whisper-turn-x-9") == nil)
        #expect(client.turnSequence(fromClientEventID: "evt_abc123") == nil)
        #expect(client.turnSequence(fromClientEventID: nil) == nil)
    }
}

// MARK: - Polish plausibility guard

@Suite struct PolishPlausibilityTests {
    private let polisher = TranscriptPolisher()

    @Test func emptyResultIsImplausible() {
        #expect(!polisher.isPlausible("", from: "随便说了点什么"))
    }

    @Test func summarySmellIsRejectedForLongInput() {
        let raw = String(repeating: "这是一段相当长的原始转写内容", count: 4)
        #expect(!polisher.isPlausible("好的。", from: raw))
    }

    @Test func replySmellIsRejected() {
        // The model answering the transcript instead of tidying it.
        #expect(!polisher.isPlausible(
            String(repeating: "这是一个膨胀了很多倍的回答", count: 3),
            from: "今天天气怎么样"
        ))
    }

    @Test func shortUtterancesAreExempt() {
        #expect(polisher.isPlausible("对。", from: "对"))
        #expect(polisher.isPlausible("可以。", from: "嗯嗯嗯那个那个我觉得就是嗯可以"))
    }

    @Test func ordinaryCleanupPasses() {
        let raw = "嗯我觉得这个方案就是那个整体上是可以接受的但是有一些细节需要再讨论一下"
        let cleaned = "我觉得这个方案整体上是可以接受的，但有一些细节需要再讨论。"
        #expect(polisher.isPlausible(cleaned, from: raw))
    }
}

// MARK: - Settings tables

@Suite struct TriggerKeyTests {
    @Test func deviceMasksAreDistinct() {
        let masks = TriggerKey.allCases.map(\.deviceMask)
        #expect(Set(masks).count == masks.count)
    }

    @Test func ownModifierIsNeverForeign() {
        // Holding the trigger key itself must not read as "user is typing a
        // shortcut" — that would cancel every dictation instantly.
        let command: UInt64 = 0x0010_0000
        let option: UInt64 = 0x0008_0000
        #expect(TriggerKey.rightCommand.foreignModifierMask & command == 0)
        #expect(TriggerKey.leftCommand.foreignModifierMask & command == 0)
        #expect(TriggerKey.rightOption.foreignModifierMask & option == 0)
        #expect(TriggerKey.leftOption.foreignModifierMask & option == 0)
    }

    @Test func fnTreatsAllStandardModifiersAsForeign() {
        let all: UInt64 = 0x0002_0000 | 0x0004_0000 | 0x0008_0000 | 0x0010_0000
        #expect(TriggerKey.fn.foreignModifierMask == all)
    }
}

@Suite struct SettingsTableTests {
    @Test func holdThresholdsAreOrdered() {
        #expect(HoldThreshold.quick.milliseconds < HoldThreshold.standard.milliseconds)
        #expect(HoldThreshold.standard.milliseconds < HoldThreshold.deliberate.milliseconds)
    }

    @Test func onlyTheRealtimeModelTypesLive() {
        // Measured behavior the whole output-mode design hangs on: the
        // gpt-4o-transcribe models emit zero deltas before the commit.
        #expect(TranscriptionModel.realtimeWhisper.supportsLiveTyping)
        #expect(!TranscriptionModel.transcribe.supportsLiveTyping)
        #expect(!TranscriptionModel.miniTranscribe.supportsLiveTyping)
    }
}

// MARK: - Keychain input validation

@Suite struct KeychainInputTests {
    @Test func whitespaceOnlyKeysAreRejectedWithoutTouchingTheKeychain() {
        // A rejected save must return false — SettingsView reports true as
        // "已存入钥匙串", and a silent delete under that message once shipped.
        #expect(!KeychainStore.saveAPIKey(""))
        #expect(!KeychainStore.saveAPIKey("   "))
        #expect(!KeychainStore.saveAPIKey(" \n\t"))
    }
}

// MARK: - Audio constants

@Suite struct AudioFormatTests {
    @Test func bytesPerSecondMatches24kHzPCM16Mono() {
        // RealtimeClient's buffer capacity and upload-stall math all key off
        // this constant; the session is configured for audio/pcm at 24 kHz.
        #expect(AudioCapture.bytesPerSecond == 24_000 * 2)
    }
}
