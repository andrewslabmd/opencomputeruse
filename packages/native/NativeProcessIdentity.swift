import Darwin
import Foundation

// Kernel process creation time is available independently of LaunchServices.
// Keep seconds/microseconds exact; optional AppKit metadata is not identity.
struct NativeProcessIdentity: Equatable {
    let pid: pid_t
    let uid: uid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func read(_ pid: pid_t) throws -> NativeProcessIdentity? {
        guard pid > 0 else { throw NativeProcessIdentityFailure(message: "Invalid native process ID.") }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        let nativeError = errno
        guard count == size else {
            if count <= 0 && nativeError == ESRCH { return nil }
            throw NativeProcessIdentityFailure(message: "Reading native process identity failed (errno \(nativeError), bytes \(count)/\(size)).")
        }
        if info.pbi_status == SZOMB { return nil }
        guard info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000 else {
            throw NativeProcessIdentityFailure(message: "The kernel returned an invalid native process identity.")
        }
        return NativeProcessIdentity(pid: pid, uid: info.pbi_uid,
            startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
    }
}

struct NativeProcessIdentityFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
