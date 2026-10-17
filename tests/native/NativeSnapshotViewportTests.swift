import XCTest
@testable import ComputerUseHelper

final class NativeSnapshotViewportTests: XCTestCase {
    func testOwningWindowDoesNotClipItsWiderSheetOrMenu() {
        let owner = CGRect(x:200,y:100,width:600,height:500)
        let sheet = CGRect(x:62,y:168,width:880,height:448)
        XCTAssertNil(NativeSnapshotViewport.children(role:"AXWindow",frame:owner,inherited:nil))
        XCTAssertNil(NativeSnapshotViewport.children(role:"AXSheet",frame:sheet,inherited:owner))
        XCTAssertNil(NativeSnapshotViewport.children(role:"AXMenu",frame:sheet,inherited:owner))
    }
    func testNestedScrollViewportsCannotExposeClippedContent() {
        let outer=CGRect(x:100,y:100,width:200,height:200)
        let inner=CGRect(x:0,y:0,width:400,height:400)
        XCTAssertEqual(NativeSnapshotViewport.children(role:"AXScrollArea",frame:inner,inherited:outer),outer)
        XCTAssertEqual(NativeSnapshotViewport.children(role:"AXGroup",frame:inner,inherited:outer),outer)
    }
}
