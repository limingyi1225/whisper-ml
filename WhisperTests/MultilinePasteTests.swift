import Foundation
import Testing
@testable import Whisper

@Suite struct MultilinePasteTests {
    @Test func incidentSuffixNeverUsesUnicodeEvenAsAFallback() {
        let suffix = "，比如说我的 Oura 的数据还没同步过来的时候，它刷新完好像还是会加载，但是显示的就是昨天的东西。\n\n我感觉理论上在我数据不齐的时候，就不应该显示东西，不然我就有点分不清到底是昨天还是啥"
        #expect(suffix.count == 94)
        #expect(TextInjector.requiresPaste(suffix))
        #expect(!TextInjector.pasteMayUseUnicodeFallback(suffix, isReplacement: false))
        #expect(!TextInjector.pasteMayUseUnicodeFallback(suffix, isReplacement: true))
        // The new route pastes this entire value; the problematic old chunk ended
        // in 不齐 and mixed two newline scalars with ordinary text.
        #expect(String(decoding: TextInjector.chunked(Array(suffix.utf16))[3], as: UTF16.self)
            == "西。\n\n我感觉理论上在我数据不齐")
    }

    @Test func allLineSeparatorsUsePasteButOrdinaryLiveTypingKeepsWorking() {
        for separator in ["\n", "\r", "\r\n", "\u{0085}", "\u{2028}", "\u{2029}"] {
            #expect(TextInjector.requiresPaste("前" + separator + "后"))
        }
        #expect(!TextInjector.requiresPaste("普通的中文🙂 English\ttext"))
        #expect(TextInjector.pasteMayUseUnicodeFallback("普通文字", isReplacement: false))
        #expect(!TextInjector.pasteMayUseUnicodeFallback("普通文字", isReplacement: true))
    }

    @Test func failedPreparationOrChangedInputNeverDeletesAnything() {
        var posted = false
        var authorized = false
        #expect(!TextInjector.commitPreparedPaste(prepare: { () -> Int? in nil }, authorize: {
            authorized = true
            return true
        }, post: { _ in posted = true }))
        #expect(!authorized && !posted)
        #expect(!TextInjector.commitPreparedPaste(prepare: { 98 }, authorize: { false }, post: { _ in posted = true }))
        #expect(!posted)
    }

    @Test func inputIsRecheckedAfterPreparationAndBeforeTheFirstMutation() {
        var order: [String] = []
        var postedCount = 0
        let committed = TextInjector.commitPreparedPaste(prepare: {
            order.append("prepare")
            return 98
        }, authorize: {
            order.append("authorize")
            return true
        }, post: { count in
            postedCount = count
            order.append("post")
        })
        #expect(committed && postedCount == 98)
        #expect(order == ["prepare", "authorize", "post"])
    }

    @Test func pasteVerificationUsesTheReplacementStartAndUTF16Offsets() throws {
        let range = try #require(TextInjector.replacementSelection(CFRange(location: 111, length: 0), deletedUTF16: 98))
        #expect(range.location == 13 && range.length == 98)
        #expect(TextInjector.selectionMatches(snapshot: range, current: CFRange(location: 107, length: 0), insertedUTF16Count: 94))
        let emoji = try #require(TextInjector.replacementSelection(CFRange(location: 8, length: 0), deletedUTF16: "🙂字".utf16.count))
        #expect(emoji.location == 5 && emoji.length == 3)
        #expect(TextInjector.replacementSelection(CFRange(location: 5, length: 1), deletedUTF16: 3) == nil)
        #expect(TextInjector.replacementSelection(CFRange(location: 2, length: 0), deletedUTF16: 3) == nil)
    }
}
