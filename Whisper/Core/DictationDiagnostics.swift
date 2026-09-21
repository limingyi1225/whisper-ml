import Foundation
import OSLog

/// Explicitly enabled on a machine while investigating text delivery. No audio,
/// credentials, clipboard snapshots, or network payloads enter this file.
@MainActor
enum DictationDiagnostics {
    static let preferenceKey = "dictationDiagnosticsEnabled"
    private static let writer = DictationDiagnosticWriter(directory: FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Whisper"))
    private static let processSession = UUID().uuidString
    private static var utteranceID: String?
    private static var sequence = 0

    static var isRecording: Bool { utteranceID != nil }

    static func startup() {
        guard UserDefaults.standard.bool(forKey: preferenceKey) else { return }
        write("diagnostics_started", fields: [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "deliveryEvidence": "posted events are not an editor acknowledgement"
        ])
    }

    static func begin(fields: [String: String]) {
        guard UserDefaults.standard.bool(forKey: preferenceKey) else {
            utteranceID = nil
            return
        }
        if utteranceID != nil { end(reason: "superseded") }
        utteranceID = UUID().uuidString
        record("utterance_begin", fields: fields)
    }

    static func record(_ event: String, texts: [String: String] = [:], fields: [String: String] = [:]) {
        guard isRecording else { return }
        var values = fields
        for (name, text) in texts {
            values.merge(textFields(text, name: name)) { _, new in new }
        }
        write(event, fields: values)
    }

    static func end(reason: String) {
        record("utterance_end", fields: ["reason": reason])
        utteranceID = nil
    }

    static func textFields(_ text: String, name: String) -> [String: String] {
        // A runaway provider response must not create an unbounded log record.
        let retained = String(text.prefix(16_384))
        return [
            name: retained,
            name + "Characters": String(text.count),
            name + "UTF16": String(text.utf16.count),
            name + "Truncated": String(retained != text),
            name + "NewlineUTF16Offsets": text.utf16.enumerated()
                .filter { $0.element == 10 || $0.element == 13 }
                .prefix(1_024).map { String($0.offset) }.joined(separator: ",")
        ]
    }

    private static func write(_ event: String, fields: [String: String]) {
        sequence += 1
        var row = fields
        row["event"] = event
        row["session"] = processSession
        row["utterance"] = utteranceID ?? "none"
        row["sequence"] = String(sequence)
        row["timestamp"] = String(Date().timeIntervalSince1970)
        row["uptime"] = String(ProcessInfo.processInfo.systemUptime)
        writer.append(row)
    }
}

/// Serialization and disk work never block keyboard event posting. All filesystem
/// operations are serialized; two bounded files survive application restarts.
nonisolated final class DictationDiagnosticWriter: @unchecked Sendable {
    private let directory: URL
    private let maxBytes: UInt64
    private let queue = DispatchQueue(label: "Whisper.dictation-diagnostics", qos: .utility)
    private let log = Logger(subsystem: "com.mingyili.Whisper", category: "diagnostics")

    init(directory: URL, maxBytes: UInt64 = 2 * 1_024 * 1_024) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    func append(_ row: [String: String]) {
        queue.async { [self] in
            do { try appendSynchronously(row) }
            catch { log.error("could not write local dictation diagnostics") }
        }
    }

    /// For tests and orderly shutdown only, never called on the dictation path.
    func flush() { queue.sync {} }

    private func appendSynchronously(_ row: [String: String]) throws {
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        data.append(10)
        guard data.count <= maxBytes else { return }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let current = directory.appendingPathComponent("dictation.jsonl")
        let previous = directory.appendingPathComponent("dictation.previous.jsonl")
        if files.fileExists(atPath: current.path) {
            let size = (try files.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.uint64Value ?? 0
            if size + UInt64(data.count) > maxBytes {
                if files.fileExists(atPath: previous.path) { try files.removeItem(at: previous) }
                try files.moveItem(at: current, to: previous)
            }
        }
        if !files.fileExists(atPath: current.path) {
            guard files.createFile(atPath: current.path, contents: nil,
                                   attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
