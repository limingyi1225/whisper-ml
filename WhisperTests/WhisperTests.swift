import DictationKit
import Foundation
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

@Suite struct SimplifiedChineseTests {
    @Test func convertsTraditionalToSimplified() {
        #expect(DictationController.simplifiedChinese("這個功能很好用") == "这个功能很好用")
        #expect(DictationController.simplifiedChinese("餘額不足") == "余额不足")
        #expect(DictationController.simplifiedChinese("他說的沒錯") == "他说的没错")
    }

    @Test func picksTheRightSimplifiedFormForMergedCharacters() {
        // The characters simplified Chinese merges are where a character-level
        // transform can go wrong; these are the ones it gets right.
        #expect(DictationController.simplifiedChinese("頭髮很長") == "头发很长")
        #expect(DictationController.simplifiedChinese("幹活了") == "干活了")
        #expect(DictationController.simplifiedChinese("皇后／後來") == "皇后／后来")
        #expect(DictationController.simplifiedChinese("麵條") == "面条")
        // Already correct in both scripts — must not be "corrected" into 着.
        #expect(DictationController.simplifiedChinese("著名的作家") == "著名的作家")
    }

    @Test func leavesSimplifiedAndLatinAlone() {
        #expect(DictationController.simplifiedChinese("这个已经是简体了") == "这个已经是简体了")
        #expect(DictationController.simplifiedChinese("backend deadline") == "backend deadline")
        #expect(DictationController.simplifiedChinese("") == "")
        // Mixed dictation is the normal case here.
        #expect(DictationController.simplifiedChinese("Kevin 說明天開會") == "Kevin 说明天开会")
    }

    @Test func isIdempotent() {
        // `finish` converts text the deltas already converted; a second pass must
        // be a no-op or every live-typed sentence would trigger a rewrite.
        let once = DictationController.simplifiedChinese("這個範圍後面還有頭髮")
        #expect(DictationController.simplifiedChinese(once) == once)
    }

    @Test func theTransformReadsAcrossCharacters() {
        // The reason `stableSimplifiedPrefix` exists. If this ever stops holding,
        // the lookahead is dead weight — but it holds on the shipping ICU.
        #expect(DictationController.simplifiedChinese("著") == "着")
        #expect(DictationController.simplifiedChinese("著名") == "著名")
    }
}

@Suite struct StableSimplifiedPrefixTests {
    /// Sentences whose conversion depends on characters that follow, mixed with
    /// ordinary ones so the corpus is not only pathological cases.
    private let corpus = [
        "這個著名的作家寫了很多書",
        "書上著錄了這件事",
        "他著手處理這件事情",
        "穿著一件衣服出門",
        "一著急就這樣",
        "我們著重討論",
        "土著居民的生活",
        "顯著提高了效率",
        "這本書著者不詳",
        "這個著名。他著手了",
        "乾隆的頭髮，還有著名的畫",
        "麵條和麵包都很好吃",
        "後來我發現範圍不對",
        "只有一隻貓在裡面",
        "臺灣的資料庫工程師",
        "頭髮長了該剪了",
        "Kevin 說明天開會討論這個範圍",
    ]

    @Test func everyPrefixShownIsAPrefixOfTheFinalText() {
        // The property live typing depends on: whatever is on screen mid-utterance
        // must still be correct once the rest of the sentence arrives. Any
        // violation means a character was typed that the completed transcript
        // disagrees with — a visible flicker at best, a wrong character at worst.
        for line in corpus {
            let whole = DictationController.simplifiedChinese(line)
            let characters = Array(line)
            for split in 1...characters.count {
                let shown = DictationController.stableSimplifiedPrefix(
                    String(characters[0..<split])
                )
                #expect(
                    whole.hasPrefix(shown),
                    "「\(String(characters[0..<split]))」 showed 「\(shown)」, not a prefix of 「\(whole)」"
                )
            }
        }
    }

    @Test func convertingEachDeltaAloneWouldBreakThatProperty() {
        // Guards the fix, not just the behavior: the naive per-delta conversion
        // this replaced really does produce a character the whole sentence never
        // would, so the test above is not vacuous.
        let pieces = ["這個著", "名的作家"]
        let naive = pieces.map(DictationController.simplifiedChinese).joined()
        let whole = DictationController.simplifiedChinese(pieces.joined())
        #expect(naive == "这个着名的作家")
        #expect(whole == "这个著名的作家")
        #expect(naive != whole)
    }

    @Test func withheldTailIsTakenAfterConvertingTheWholeText() {
        // The subtle half of the fix. Converting `raw.dropLast()` would answer
        // 「这个着」 here — correct-looking, and wrong, because dropping 名 also
        // drops the context that keeps 著 as 著.
        #expect(DictationController.stableSimplifiedPrefix("這個著名") == "这个著")
        #expect(DictationController.stableSimplifiedPrefix("這個著") == "这个")
    }

    @Test func completeTextIsNeverWithheld() {
        // The flush path: once the transcript is complete, nothing is held back.
        #expect(DictationController.simplifiedChinese("這個著名的作家") == "这个著名的作家")
    }

    @Test func latinAndPunctuationDoNotLag() {
        // Only CJK can be rewritten, so English dictation must stream at full speed.
        #expect(DictationController.stableSimplifiedPrefix("hello") == "hello")
        #expect(DictationController.stableSimplifiedPrefix("這個範圍。") == "这个范围。")
        #expect(DictationController.stableSimplifiedPrefix("") == "")
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

    @Test func translatesTheGeoBlock() {
        // The message OpenAI actually returns when the request leaves over
        // un-proxied UDP; without this it reaches the pill as raw English.
        #expect(DictationController.friendlyMessage("Country, region, or territory not supported")
            == "OpenAI 不支持这个地区")
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

    @Test func transliteratedNamesMayExpand() {
        // The exact output measured from the model. 9 characters becoming 16 is
        // 1.8×, past the plain 1.6× ceiling — rejecting it would hand the user
        // back "凯文和艾米", which is what the name rule exists to fix.
        #expect(polisher.isPlausible("Kevin 和 Amy 明天过来", from: "凯文和艾米明天过来"))
        #expect(polisher.isPlausible("Kevin", from: "凯文"))
    }

    @Test func vocabularyExpansionIsAllowedWithTheList() {
        // A Chinese term that is longer than what was misheard gets no help from
        // the Latin measure; it has to be covered by the list itself.
        #expect(polisher.isPlausible(
            "中国科学技术大学",
            from: "中科大",
            vocabulary: ["中国科学技术大学"]
        ))
        #expect(!polisher.isPlausible("中国科学技术大学", from: "中科大"))
    }

    @Test func slackOnlyCoversTermsThatActuallyCameBack() {
        // A long list must not silently disarm the guard: the reply below contains
        // none of the listed terms, so it gets no slack and stays implausible.
        #expect(!polisher.isPlausible(
            String(repeating: "这是一个膨胀了很多倍的回答", count: 3),
            from: "今天天气怎么样",
            vocabulary: ["Anthropic", "Kubernetes", "TypeScript", "李明一"]
        ))
    }

    @Test func anEnglishReplyStillTripsTheGuard() {
        // Latin slack is capped at roughly the raw length, so the model answering
        // in English cannot buy its way past the ceiling one letter at a time.
        #expect(!polisher.isPlausible(
            "The weather today is quite nice and sunny outside.",
            from: "今天天气怎么样"
        ))
    }
}

// MARK: - Cleanup prompt

@Suite struct PolishInstructionsTests {
    @Test func emptyVocabularyAddsNothing() {
        // Users who never open that box should be running exactly the prompt that
        // was tuned without it.
        #expect(!TranscriptPolisher.instructions(vocabulary: []).contains("常用词汇表"))
    }

    @Test func vocabularyIsListedVerbatimAndIsAdditive() {
        let base = TranscriptPolisher.instructions(vocabulary: [])
        let withTerms = TranscriptPolisher.instructions(vocabulary: ["Kevin", "李明一"])
        #expect(withTerms.hasPrefix(base))
        #expect(withTerms.contains("Kevin"))
        #expect(withTerms.contains("李明一"))
    }

    @Test func properNounsAreNoLongerOffLimits() {
        // The old blanket "never touch names" rule is what made a vocabulary
        // list unusable; if it comes back, the feature silently stops working.
        #expect(!TranscriptPolisher.instructions(vocabulary: ["Kevin"])
            .contains("人名、产品名、专业术语、代码标识符即使看起来奇怪也不要动"))
    }

    @Test func transliteratedNameRuleAppliesWithoutAVocabulary() {
        // The name rule is part of the base prompt, not the vocabulary block —
        // an empty list must still turn 艾米 into Amy.
        let base = TranscriptPolisher.instructions(vocabulary: [])
        #expect(base.contains("艾米→Amy"))
        #expect(base.contains("中文名字保持中文"))
    }
}

// MARK: - Vocabulary parsing

@Suite struct VocabularyParsingTests {
    @Test func splitsTrimsAndKeepsOrder() {
        #expect(AppSettings.parseVocabulary("Kevin\n  李明一  \nAnthropic")
            == ["Kevin", "李明一", "Anthropic"])
    }

    @Test func dropsBlanksAndDuplicates() {
        #expect(AppSettings.parseVocabulary("\n\nKevin\n \nKevin\n") == ["Kevin"])
        #expect(AppSettings.parseVocabulary("") == [])
        #expect(AppSettings.parseVocabulary("   \n\t\n") == [])
    }

    @Test func dropsOverlongLinesRatherThanTruncating() {
        // Half a sentence is not a spelling anybody wants enforced.
        let essay = String(repeating: "词", count: AppSettings.vocabularyTermLengthLimit + 1)
        #expect(AppSettings.parseVocabulary("Kevin\n\(essay)") == ["Kevin"])
        let atLimit = String(repeating: "词", count: AppSettings.vocabularyTermLengthLimit)
        #expect(AppSettings.parseVocabulary(atLimit) == [atLimit])
    }

    @Test func capsTheListLength() {
        // Every term rides along in every cleanup request.
        let many = (1...(AppSettings.vocabularyTermLimit + 20))
            .map { "term\($0)" }
            .joined(separator: "\n")
        #expect(AppSettings.parseVocabulary(many).count == AppSettings.vocabularyTermLimit)
    }

    @Test func builtInNamesRideAlongWithAnEmptyBox() {
        // The names of the people using the app are never typed into Settings, so an
        // empty box still has to reach the cleanup model with something in it.
        #expect(AppSettings.vocabularyTerms(userList: "") == AppSettings.builtInVocabulary)
    }

    @Test func builtInNamesComeFirstAndAreNotDuplicated() {
        let terms = AppSettings.vocabularyTerms(userList: "Kevin\n李铭一\nAnthropic")
        #expect(terms == AppSettings.builtInVocabulary + ["Kevin", "Anthropic"])
        #expect(terms.count { $0 == "李铭一" } == 1)
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

    @Test func onlySupportedTriggerKeysAreExposed() {
        #expect(TriggerKey.allCases.map(\.rawValue) == [
            "rightCommand", "leftCommand", "rightOption", "leftOption"
        ])
        #expect(TriggerKey(rawValue: "fn") == nil)
    }
}

@Suite struct SettingsTableTests {
    @Test func onlyTheRealtimeModelTypesLive() {
        // Measured behavior the whole output-mode design hangs on: the
        // gpt-4o-transcribe models emit zero deltas before the commit.
        #expect(TranscriptionModel.realtimeWhisper.supportsLiveTyping)
        #expect(!TranscriptionModel.transcribe.supportsLiveTyping)
        #expect(!TranscriptionModel.miniTranscribe.supportsLiveTyping)
    }
}

// MARK: - Keychain input validation

@Suite struct BundledTokenSeedingTests {
    /// Issuance numbers, standing in for `date +%s` at packaging time.
    private let older = 1_700_000_000
    private let newer = 1_800_000_000

    /// The sequence the packaging flow exists for, and the one the first version broke:
    /// seed a token, revoke it server-side, hand over a rebuilt copy. Deleting the app
    /// does not clear a keychain item, so if the new token cannot replace the old one
    /// the recipient is stuck on 401 with no way out from their side.
    @Test func aRebuiltCopyReplacesTheTokenItInstalledBefore() {
        // Nothing stored yet.
        #expect(KeychainStore.shouldSeed(
            hasStoredToken: false, bundledIssuance: older, adoptedIssuance: nil
        ))
        // Already applied this exact issuance — writing again would be pointless churn.
        #expect(!KeychainStore.shouldSeed(
            hasStoredToken: true, bundledIssuance: older, adoptedIssuance: older
        ))
        // A newer issuance replaces what this app installed before. The rotation case.
        #expect(KeychainStore.shouldSeed(
            hasStoredToken: true, bundledIssuance: newer, adoptedIssuance: older
        ))
    }

    /// The identity a personalised build registers has to be the identity it uses, or
    /// revocation quietly stops working: the ledger says "alice = B" while alice's Mac
    /// authenticates with a token she was given earlier, so `revoke_token.sh alice`
    /// removes a hash nobody is using and she keeps dictating. Applying this build's own
    /// token once is what makes the two agree.
    @Test func aPersonalisedBuildAdoptsItsOwnIdentityOverAnUnknownStoredToken() {
        #expect(KeychainStore.shouldSeed(
            hasStoredToken: true, bundledIssuance: older, adoptedIssuance: nil
        ))
    }

    /// …but exactly once. The issuance is recorded even though the user later replaces
    /// the token by hand, so the same build cannot reinstall itself on every launch and
    /// overwrite their choice forever.
    @Test func aTokenTheUserTypedAfterwardsSurvivesRelaunching() {
        #expect(!KeychainStore.shouldSeed(
            hasStoredToken: true, bundledIssuance: older, adoptedIssuance: older
        ))
    }

    /// Opening an older copy must not undo a newer one. This is the downgrade a
    /// value-comparison marker could not see: it proved only "this app wrote the current
    /// value", never which of two tokens came first, so the old copy read a working token
    /// as its own stale leftover and wrote a revoked one back over it.
    @Test func anOlderCopyNeverDowngradesANewerToken() {
        #expect(!KeychainStore.shouldSeed(
            hasStoredToken: true, bundledIssuance: older, adoptedIssuance: newer
        ))
        // And the 401 path cannot be used as a way around it — otherwise the downgrade
        // just happens one rejection later, to a token that is already revoked.
        #expect(!KeychainStore.mayRecoverWithBundled(
            bundledIssuance: older, adoptedIssuance: newer
        ))
    }

    /// A build with a token but no issuance stamp predates the ordering entirely, so it
    /// cannot be placed against anything: it may fill an empty slot and nothing more.
    @Test func anUnstampedBuildOnlyFillsAnEmptySlot() {
        #expect(KeychainStore.shouldSeed(
            hasStoredToken: false, bundledIssuance: nil, adoptedIssuance: nil
        ))
        #expect(!KeychainStore.shouldSeed(
            hasStoredToken: true, bundledIssuance: nil, adoptedIssuance: nil
        ))
        #expect(!KeychainStore.shouldSeed(
            hasStoredToken: true, bundledIssuance: nil, adoptedIssuance: older
        ))
    }

    /// Recovery from a rejected token is deliberately more permissive than seeding: a
    /// 401 is evidence the stored value does not work, which seeding never has.
    @Test func recoveryReinstallsThisBuildsTokenButNeverAnOlderOne() {
        // No history: the migration case, where there is nothing to contradict it.
        #expect(KeychainStore.mayRecoverWithBundled(bundledIssuance: older, adoptedIssuance: nil))
        // Its own issuance, re-applied — the stored value was hand-typed or rotated out.
        #expect(KeychainStore.mayRecoverWithBundled(bundledIssuance: older, adoptedIssuance: older))
        #expect(KeychainStore.mayRecoverWithBundled(bundledIssuance: newer, adoptedIssuance: older))
        // Unorderable against a real history — refuse rather than guess.
        #expect(!KeychainStore.mayRecoverWithBundled(bundledIssuance: nil, adoptedIssuance: older))
    }
}

@Suite struct KeychainInputTests {
    @Test func whitespaceOnlyKeysAreRejectedWithoutTouchingTheKeychain() {
        // A rejected save must return false — SettingsView reports true as
        // "已存入钥匙串", and a silent delete under that message once shipped.
        #expect(!KeychainStore.saveAPIKey(""))
        #expect(!KeychainStore.saveAPIKey("   "))
        #expect(!KeychainStore.saveAPIKey(" \n\t"))
    }

    @Test func whitespaceOnlyRelayTokensAreRejectedWithoutTouchingTheKeychain() {
        #expect(!KeychainStore.saveRelayToken(""))
        #expect(!KeychainStore.saveRelayToken("   "))
        #expect(!KeychainStore.saveRelayToken(" \n\t"))
    }
}

// MARK: - Relay routing

/// `.serialized` because `onlyALoopbackOverrideIsHonoured` writes the app's real
/// `UserDefaults` domain. Nothing else reads that key today, so this is locking in the
/// precondition rather than fixing an observed flake.
@Suite(.serialized) struct ServiceRouteTests {
    @Test func configuredRelayUsesHTTPS() {
        #expect(ServiceRoute.relayBaseURL.scheme == "https")
        #expect(ServiceRoute.relayBaseURL.host == "limingyi.com")
        #expect(ServiceRoute.relayBaseURL.path == "/whisper-relay")
    }

    @Test func loopbackHTTPIsAllowedForDevelopment() {
        #expect(ServiceRoute.relayBaseURL(from: "http://localhost:8787") != nil)
        #expect(ServiceRoute.relayBaseURL(from: "http://127.0.0.1:8787") != nil)
        #expect(ServiceRoute.relayBaseURL(from: "http://[::1]:8787") != nil)
    }

    @Test func credentialsQueryAndFragmentAreRejected() {
        #expect(ServiceRoute.relayBaseURL(from: "https://user@relay.example.com") == nil)
        #expect(ServiceRoute.relayBaseURL(from: "https://relay.example.com?token=secret") == nil)
        #expect(ServiceRoute.relayBaseURL(from: "https://relay.example.com/#secret") == nil)
    }

    @Test func relayPathsPreserveAnOptionalBasePath() throws {
        let base = try #require(
            ServiceRoute.relayBaseURL(from: "https://relay.example.com/whisper/")
        )
        #expect(base.appendingPathComponent("v1/polish").absoluteString
            == "https://relay.example.com/whisper/v1/polish")
        #expect(ServiceRoute.relayRealtimeURL(baseURL: base).absoluteString
            == "wss://relay.example.com/whisper/v1/realtime?intent=transcription")
    }

    /// The deployed relay is published under a path prefix, so these are the exact
    /// strings the server has to answer on.
    @Test func productionRelayPathsMatchTheDeployedPrefix() {
        #expect(ServiceRoute.relayBaseURL.appendingPathComponent("v1/polish")
            .absoluteString == "https://limingyi.com/whisper-relay/v1/polish")
        #expect(ServiceRoute.relayRealtimeURL(baseURL: ServiceRoute.relayBaseURL)
            .absoluteString
            == "wss://limingyi.com/whisper-relay/v1/realtime?intent=transcription")
    }

    /// A stale or malformed development override must not be able to brick the app,
    /// and — the reason this is loopback-only — must never be usable to point a build
    /// holding a real device token at someone else's server. `UserDefaults` is writable
    /// by anything running as this user, so an override honouring arbitrary HTTPS hosts
    /// would make the app itself hand the Keychain token to an attacker on reconnect.
    @Test func onlyALoopbackOverrideIsHonoured() {
        let key = ServiceRoute.relayBaseURLOverrideKey
        let store = UserDefaults.standard
        let saved = store.string(forKey: key)
        defer {
            if let saved { store.set(saved, forKey: key) } else { store.removeObject(forKey: key) }
        }

        let rejected = [
            "", "not a url", "ftp://relay.example.com",
            "http://relay.example.com",
            // Valid, TLS, parses fine — and still refused, because it is not loopback.
            "https://attacker.example.com",
            "https://127.0.0.1.attacker.example.com",
        ]
        for bad in rejected {
            store.set(bad, forKey: key)
            #expect(
                ServiceRoute.effectiveRelayBaseURL == ServiceRoute.relayBaseURL,
                "override \"\(bad)\" must not be honoured"
            )
        }

        store.removeObject(forKey: key)
        #expect(ServiceRoute.effectiveRelayBaseURL == ServiceRoute.relayBaseURL)

        store.set("http://127.0.0.1:8787", forKey: key)
        #if DEBUG
        #expect(ServiceRoute.effectiveRelayBaseURL.absoluteString == "http://127.0.0.1:8787")
        #else
        #expect(ServiceRoute.effectiveRelayBaseURL == ServiceRoute.relayBaseURL)
        #endif
    }

    /// The struct holds a plaintext credential and now survives a whole utterance, so
    /// the one thing that must never happen is it being interpolated into a log line.
    @Test func interpolatingARouteNeverPrintsTheCredential() {
        let route = ServiceRoute(
            mode: .relay,
            realtimeURL: URL(string: "wss://relay.example.com/v1/realtime")!,
            polishURL: URL(string: "https://relay.example.com/v1/polish")!,
            credential: "relay_super-secret-token"
        )
        let logged = "route=\(route)"
        #expect(!logged.contains("relay_super-secret-token"))
        // Still has to be worth logging: mode and host are the two facts that matter.
        #expect(logged.contains("relay"))
        #expect(logged.contains("relay.example.com"))
    }

    /// `URLSessionWebSocketTask` collapses every rejected handshake into one opaque
    /// `NSURLErrorBadServerResponse` ("There was a bad response from the server"), so
    /// without reading the status off the task's `response` a revoked device token is
    /// indistinguishable from a dead café Wi-Fi — and the app burns all six backoff
    /// attempts on a credential that will never start working.
    @Test func aRejectedHandshakeSaysWhichPeerRefusedItAndWhetherRetryingHelps() {
        let unauthorized = RealtimeClient.handshakeRejection(statusCode: 401, viaRelay: true)
        #expect(unauthorized.message.contains("设备 Token"))
        #expect(unauthorized.retryable == false)
        // The one failure a personalised build may repair by installing its bundled
        // token: our relay's auth answers a bad token with 401 and nothing else.
        #expect(unauthorized.rejectedCredential)

        let badKey = RealtimeClient.handshakeRejection(statusCode: 403, viaRelay: false)
        #expect(badKey.message.contains("API Key"))
        #expect(badKey.retryable == false)

        // A relay-path 403 is Cloudflare or nginx, never the relay itself — it does
        // not send 403. Marking it a rejected credential once let one transient edge
        // hiccup *permanently* overwrite a hand-typed token with the bundled one.
        let edge = RealtimeClient.handshakeRejection(statusCode: 403, viaRelay: true)
        #expect(edge.rejectedCredential == false)
        #expect(edge.retryable)
        #expect(edge.message.contains("403"))
        #expect(!edge.message.contains("重新填写"))

        // Usually this device's own sleep/wake zombies still holding their slots. The
        // relay's heartbeat reaps them within a sweep or two, so this one must keep
        // retrying rather than stranding the user on a self-healing error.
        let throttled = RealtimeClient.handshakeRejection(statusCode: 429, viaRelay: true)
        #expect(throttled.message.contains("429"))
        #expect(throttled.retryable)

        // Anything unclassified still beats "There was a bad response from the server":
        // the status is the one fact that says whether it is the relay or the edge.
        let gateway = RealtimeClient.handshakeRejection(statusCode: 502, viaRelay: true)
        #expect(gateway.message.contains("502"))
        #expect(gateway.message.contains("转发服务器"))
        #expect(gateway.retryable)
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
