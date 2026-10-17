import XCTest
@testable import ComputerUseHelper

final class NativeWindowIdentityTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 400, height: 400)
    func testExactWindowIdentityDistinguishesEqualFrames() {
        let candidates = [NativeWindowIdentity.Candidate(id: 1, frame: frame, fallbackAllowed: true),
            NativeWindowIdentity.Candidate(id: 2, frame: frame, fallbackAllowed: true)]
        XCTAssertEqual(NativeWindowIdentity.index(id: 2, frame: frame, candidates: candidates), 1)
        XCTAssertNil(NativeWindowIdentity.index(id: 3, frame: frame, candidates: candidates))
    }
    func testMissingWindowNumberOnlyFallsBackToUniqueWindowFrame() {
        let candidate = NativeWindowIdentity.Candidate(id: nil, frame: frame, fallbackAllowed: true)
        XCTAssertEqual(NativeWindowIdentity.index(id: 1, frame: frame, candidates: [candidate]), 0)
        XCTAssertNil(NativeWindowIdentity.index(id: 1, frame: frame, candidates: [candidate, candidate]))
        XCTAssertNil(NativeWindowIdentity.index(id: 1, frame: frame.offsetBy(dx: 2, dy: 0), candidates: [candidate]))
    }
    func testRootEditorNeedsNativeIdentityRatherThanRoleOrGeometryGuess() throws {
        let editor = NativeWindowIdentity.Candidate(id: 2, frame: frame, fallbackAllowed: false)
        XCTAssertEqual(NativeWindowIdentity.index(id: 2, frame: frame, candidates: [editor]), 0)
        XCTAssertNil(NativeWindowIdentity.index(id: 3, frame: frame,
            candidates: [.init(id: nil, frame: frame, fallbackAllowed: false)]))
        let root = NativeInteractionNode(id: "editor", role: "AXTextField", subrole: nil, frame: frame, children: [])
        XCTAssertEqual(try NativePointResolver.chain(root: root, nativeHitIDs: ["editor"], point: CGPoint(x: 20,y: 20)).map(\.id), ["editor"])
        XCTAssertThrowsError(try NativePointResolver.chain(root: root, nativeHitIDs: ["foreign"], point: CGPoint(x: 20,y: 20)))
    }
    func testFocusedEditorMustBelongToScopedMainDocument() {
        let popup = CGRect(x: 10,y: 20,width: 100,height: 22)
        XCTAssertTrue(NativeWindowIdentity.allowsFocusedEditorOverlay(role: "AXTextField",frame: popup,anchorFrame: frame,anchorID: 1,mainID: 1,focused: true))
        XCTAssertFalse(NativeWindowIdentity.allowsFocusedEditorOverlay(role: "AXTextField",frame: popup,anchorFrame: frame,anchorID: 1,mainID: 2,focused: true))
        XCTAssertFalse(NativeWindowIdentity.allowsFocusedEditorOverlay(role: "AXTextField",frame: popup,anchorFrame: frame,anchorID: 1,mainID: nil,focused: true))
        XCTAssertFalse(NativeWindowIdentity.allowsFocusedEditorOverlay(role: "AXTextField",frame: popup,anchorFrame: frame,anchorID: 1,mainID: 1,focused: false))
        XCTAssertFalse(NativeWindowIdentity.allowsFocusedEditorOverlay(role: "AXWindow",frame: popup,anchorFrame: frame,anchorID: 1,mainID: 1,focused: true))
        XCTAssertFalse(NativeWindowIdentity.allowsFocusedEditorOverlay(role: "AXTextField",frame: popup.offsetBy(dx: 500,dy: 0),anchorFrame: frame,anchorID: 1,mainID: 1,focused: true))
    }
}
