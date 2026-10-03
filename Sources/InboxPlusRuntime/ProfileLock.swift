import Darwin
import Foundation

@_silgen_name("flock")
private func inboxplus_flock(_ descriptor: Int32, _ operation: Int32) -> Int32

public final class ProfileLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = inboxplus_flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }

    public static func acquire(at url: URL) throws -> ProfileLock {
        guard url.isFileURL else {
            throw ProfileLockError.nonFileURL(url)
        }

        let descriptor = Darwin.open(
            url.standardizedFileURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw ProfileLockError.systemError(operation: "open", code: errno)
        }

        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw ProfileLockError.systemError(operation: "fchmod", code: code)
        }

        guard inboxplus_flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw ProfileLockError.alreadyLocked
            }
            throw ProfileLockError.systemError(operation: "flock", code: code)
        }

        return ProfileLock(descriptor: descriptor)
    }
}

public enum ProfileLockError: Error, Equatable, Sendable {
    case nonFileURL(URL)
    case alreadyLocked
    case systemError(operation: String, code: Int32)
}
