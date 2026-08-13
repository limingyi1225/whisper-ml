import Foundation
import Darwin

public struct RelayEnrollmentClient {
    private static let enrollmentGate = RelayEnrollmentGate()
    private static let processLock = RelayEnrollmentProcessLock()
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func enroll(inviteCode: String) async throws {
        let invite = inviteCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPlausibleInviteCode(invite) else {
            throw RelayEnrollmentError.message("邀请码格式不正确")
        }

        // The pending Keychain item is the transaction identity for a claim. Two
        // overlapping claims must not replace or promote each other's proposal while
        // either request is suspended in URLSession. Serialising the whole workflow
        // also covers multiple Settings windows in one process.
        await Self.enrollmentGate.acquire()
        do {
            // The Keychain is shared by every running copy signed as this app. Hold a
            // process-crash-safe advisory lock across the *whole* transaction, not just
            // individual reads and writes: Security.framework has no compare-and-delete
            // primitive, so a read/check/delete sequence alone cannot be cross-process
            // atomic. Waiting happens on the lock's private queue, never MainActor.
            let processLease = try await Self.processLock.acquire()
            defer { processLease.release() }
            try Task.checkCancellation()
            try await enroll(validatedInviteCode: invite, mayRefreshDeviceToken: true)
            await Self.enrollmentGate.release()
        } catch {
            await Self.enrollmentGate.release()
            throw error
        }
    }

    private func enroll(validatedInviteCode invite: String, mayRefreshDeviceToken: Bool) async throws {
        try Task.checkCancellation()
        let deviceToken = try KeychainStore.prepareRelayEnrollmentToken()
        var request = URLRequest(url: ServiceRoute.relayEnrollmentURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(inviteCode: invite, deviceToken: deviceToken)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw RelayEnrollmentError.message("无法连接激活服务器，请检查网络后重试")
        }
        guard let http = response as? HTTPURLResponse else {
            throw RelayEnrollmentError.message("激活服务器返回了无法识别的响应")
        }
        guard http.statusCode == 200 else {
            let error = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error
            if error?.code == "enrollment_device_token_in_use", mayRefreshDeviceToken {
                guard KeychainStore.resetPendingRelayEnrollmentToken(expectedToken: deviceToken) else {
                    throw RelayEnrollmentError.message("无法更新钥匙串中的设备身份，请重试")
                }
                try await enroll(validatedInviteCode: invite, mayRefreshDeviceToken: false)
                return
            }
            // This invite was previously committed for this exact proposal and the
            // resulting device has since been revoked. It can never succeed again;
            // keeping the proposal would poison the next fresh invite too.
            if error?.code == "enrollment_revoked" {
                _ = KeychainStore.resetPendingRelayEnrollmentToken(expectedToken: deviceToken)
            }
            throw RelayEnrollmentError.message(
                error?.message ?? Self.fallbackMessage(for: http.statusCode)
            )
        }
        guard KeychainStore.commitPendingRelayEnrollmentToken(expectedToken: deviceToken) else {
            throw RelayEnrollmentError.message("激活成功，但无法把设备身份存入钥匙串；请重试")
        }
    }

    public nonisolated static func isPlausibleInviteCode(_ value: String) -> Bool {
        let normalized = value.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard normalized.count == 39, normalized.hasPrefix("WHISPER") else { return false }
        return normalized.dropFirst(7).allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    private nonisolated static func fallbackMessage(for status: Int) -> String {
        switch status {
        case 401: "邀请码无效或已被停用"
        case 403: "这台设备的访问权限已被停用"
        case 409: "这个邀请码已经被另一台设备使用"
        case 429: "尝试次数过多，请稍后再试"
        default: "激活失败（HTTP \(status)）"
        }
    }

    private struct RequestBody: Encodable {
        let inviteCode: String
        let deviceToken: String
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorBody
    }

    private struct ErrorBody: Decodable {
        let message: String
        let code: String
    }
}

/// Serialises Keychain enrollment transactions across old/new app copies and `open -n`
/// instances. `flock` belongs to the open file descriptor, so a crash or force-quit
/// closes it in the kernel and releases the lock without recovery bookkeeping.
private final class RelayEnrollmentProcessLock: @unchecked Sendable {
    private let waitQueue = DispatchQueue(label: "com.mingyili.Whisper.relay-enrollment-lock")

    func acquire() async throws -> RelayEnrollmentProcessLease {
        let cancellation = RelayEnrollmentLockCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waitQueue.async {
                    do {
                        let descriptor = try Self.openLockFile()
                        do {
                            try Self.lock(descriptor, cancellation: cancellation)
                        } catch {
                            Darwin.close(descriptor)
                            throw error
                        }

                        if cancellation.isCancelled {
                            _ = flock(descriptor, LOCK_UN)
                            Darwin.close(descriptor)
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(
                                returning: RelayEnrollmentProcessLease(descriptor: descriptor)
                            )
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // Closing an fd from another thread while `flock` is blocked is not a
            // portable cancellation mechanism. Mark it instead; the private queue uses
            // non-blocking lock attempts and observes this flag between them. The caller
            // also checks cancellation after a successful handoff to cover that race.
            cancellation.cancel()
        }
    }

    private nonisolated static func openLockFile() throws -> Int32 {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw RelayEnrollmentLockError.unavailable
        }
        let directory = applicationSupport.appendingPathComponent(
            "com.mingyili.Whisper",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw RelayEnrollmentLockError.unavailable
        }
        // Tighten an existing directory too; createDirectory attributes only apply
        // when it is new. Failure is treated as fatal rather than using a shared lock
        // file with permissions we could not establish.
        guard Darwin.chmod(directory.path, 0o700) == 0 else {
            throw RelayEnrollmentLockError.system(errno)
        }

        let path = directory.appendingPathComponent("relay-enrollment.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RelayEnrollmentLockError.system(errno) }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw RelayEnrollmentLockError.system(code)
        }
        return descriptor
    }

    private nonisolated static func lock(
        _ descriptor: Int32,
        cancellation: RelayEnrollmentLockCancellation
    ) throws {
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK {
                if cancellation.isCancelled { throw CancellationError() }
                // This is a dedicated queue, not MainActor. Polling instead of one
                // uninterruptible flock keeps closing Settings responsive even if an
                // old copy is paused or wedged while holding its transaction.
                Darwin.usleep(50_000)
                continue
            }
            throw RelayEnrollmentLockError.system(code)
        }
    }
}

private final class RelayEnrollmentProcessLease: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func release() {
        stateLock.lock()
        let descriptor = self.descriptor
        self.descriptor = nil
        stateLock.unlock()
        guard let descriptor else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    deinit {
        release()
    }
}

private final class RelayEnrollmentLockCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private enum RelayEnrollmentLockError: LocalizedError {
    case unavailable
    case system(Int32)

    var errorDescription: String? {
        "无法锁定本机设备身份，请重试"
    }
}

/// A deliberately small async mutex. Swift actors are reentrant at every `await`, so
/// putting the enrollment method on an actor alone would still allow another claim to
/// enter while URLSession is suspended. Ownership is transferred directly to one
/// waiter on release; all other callers remain parked without blocking a thread.
private actor RelayEnrollmentGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

public enum RelayEnrollmentError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}
