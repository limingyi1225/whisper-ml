import Foundation
import Testing
@testable import Whisper

@Suite struct DictationDiagnosticsTests {
    @Test func diagnosticsPreserveReorderedWordsAndExactNewlines() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = DictationDiagnosticWriter(directory: directory)
        let text = "🙂中间\r\n末尾几个"
        var first = DictationDiagnostics.textFields(text, name: "final")
        first["event"] = "provider_final"
        writer.append(first)
        writer.append(["event": "backspace_posted_unverified", "count": "139"])
        writer.flush()
        let file = directory.appendingPathComponent("dictation.jsonl")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let row = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String])
        #expect(row["final"] == text)
        #expect(row["finalNewlineUTF16Offsets"] == "4,5")
        #expect(row["finalUTF16"] == "10")
        let second = try #require(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: String])
        #expect(second["event"] == "backspace_posted_unverified")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((folderAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func rotationIsBoundedAndASecondWriterPreservesPreviousRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = DictationDiagnosticWriter(directory: directory, maxBytes: 100)
        for index in 0..<8 { writer.append(["index": String(index), "text": String(repeating: "x", count: 40)]) }
        writer.flush()
        let restarted = DictationDiagnosticWriter(directory: directory, maxBytes: 100)
        restarted.append(["index": "8", "text": String(repeating: "x", count: 40)])
        restarted.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        for file in files { #expect(try Data(contentsOf: file).count <= 100) }
        let previous = try Data(contentsOf: directory.appendingPathComponent("dictation.previous.jsonl"))
        let current = try Data(contentsOf: directory.appendingPathComponent("dictation.jsonl"))
        #expect((try JSONSerialization.jsonObject(with: previous) as? [String: String])?["index"] == "7")
        #expect((try JSONSerialization.jsonObject(with: current) as? [String: String])?["index"] == "8")
    }

    @Test func oversizedTranscriptIsExplicitlyMarkedInsteadOfSilentlyCut() {
        let fields = DictationDiagnostics.textFields(String(repeating: "字", count: 20_000), name: "raw")
        #expect(fields["raw"]?.count == 16_384)
        #expect(fields["rawCharacters"] == "20000")
        #expect(fields["rawTruncated"] == "true")
    }
}
