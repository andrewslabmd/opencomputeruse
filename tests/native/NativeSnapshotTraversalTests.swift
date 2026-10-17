import XCTest
@testable import ComputerUseHelper

final class NativeSnapshotTraversalTests: XCTestCase {
    struct Handle: Hashable {
        let id: Int
        func hash(into hasher: inout Hasher) { hasher.combine(0) }
    }
    func testWideLargeDocumentCannotDropControlsOrSecondWindowDespiteHashCollisions() throws {
        let graph = [0: Array(2...6002), 1: [6003]]
        var reads: [Int] = []
        let traversal = NativeSnapshotTraversal<Handle, Int, [Int]>(checkCancellation: {}, read: { h, _ in reads.append(h.id); return h.id },
            children: { (graph[$0] ?? []).map { Handle(id: $0) } }, encode: { h, _, _, children in [h.id] + children.flatMap { $0 } })
        let result = try traversal.collect([Handle(id: 0), Handle(id: 1)])
        XCTAssertEqual(Array(reads.prefix(2)), [0, 1])
        XCTAssertEqual(result[0]?.count, 6002)
        XCTAssertEqual(result[0]?.last, 6002)
        XCTAssertEqual(result[1], [1, 6003])
        XCTAssertEqual(Set(reads).count, 6004)
    }
    func testDeepTreeAndCyclesTerminateWithoutDroppingUniqueNodes() throws {
        let traversal = NativeSnapshotTraversal<Int, Int, [Int]>(checkCancellation: {}, read: { n, _ in n },
            children: { $0 < 150 ? [$0 + 1] : [0] }, encode: { n, _, _, children in [n] + children.flatMap { $0 } })
        XCTAssertEqual(try traversal.collect([0])[0], Array(0...150))
    }
    func testCancelledReadDoesNotPublishPartialTree() {
        var reads = 0
        let traversal = NativeSnapshotTraversal<Int, Int, Int>(checkCancellation: {
            if reads == 3 { throw NativeProcessIdentityFailure(message: "cancelled") }
        }, read: { n, _ in reads += 1; return n }, children: { [$0 + 1] }, encode: { n, _, _, _ in n })
        XCTAssertThrowsError(try traversal.collect([0]))
        XCTAssertEqual(reads, 3)
    }
    func testNativeReadErrorFailsWholeCapture() {
        let traversal = NativeSnapshotTraversal<Int, Int, Int>(checkCancellation: {}, read: { n, _ in
            if n == 2 { throw NativeProcessIdentityFailure(message: "provider unavailable") }; return n
        }, children: { $0 == 0 ? [2] : [] }, encode: { n, _, _, _ in n })
        XCTAssertThrowsError(try traversal.collect([0, 1]))
    }
    func testRequestCancellationChecksExistingFileAndExactLiveOwner() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let identity = try XCTUnwrap(NativeProcessIdentity.read(getpid()))
        let token = NativeRequestCancellation(requestURL: url, owner: identity, parentPID: getpid())
        try token.check()
        let wrongOwner = NativeProcessIdentity(pid: identity.pid, uid: identity.uid,
            startSeconds: identity.startSeconds + 1, startMicroseconds: identity.startMicroseconds)
        XCTAssertThrowsError(try NativeRequestCancellation(requestURL: url, owner: wrongOwner, parentPID: getpid()).check())
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try token.check())
    }
}
