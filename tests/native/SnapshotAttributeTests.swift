import ApplicationServices
import XCTest
@testable import ComputerUseHelper

final class SnapshotAttributeTests: XCTestCase {
    func testURLFieldsPreserveNativeURLAndDocumentString() throws {
        let url = URL(string: "https://example.com/a%20b?x=1&y=2#part")! as NSURL
        let attributes = try AccessibilitySnapshotAttributes(results: self.results([
            "AXURL": url, "AXDocument": "file:///Users/example/Folder%20Name/Document.rtf" as NSString,
        ]))
        XCTAssertEqual(attributes.url("AXURL"), url.absoluteString)
        XCTAssertEqual(attributes.url("AXDocument"), "file:///Users/example/Folder%20Name/Document.rtf")
        XCTAssertNil(attributes.url("AXValue"))
    }
    func testContentsSupplementChildrenWithoutDuplicatingNativeHandles() throws {
        let first=AXUIElementCreateApplication(42), second=AXUIElementCreateApplication(43)
        let equalFirst=AXUIElementCreateApplication(42)
        let attributes=try AccessibilitySnapshotAttributes(results:self.results([
            "AXChildren":[first] as NSArray,"AXContents":[equalFirst,second] as NSArray,
        ]))
        XCTAssertEqual(attributes.children.count,2)
        XCTAssertTrue(CFEqual(attributes.children[0],first))
        XCTAssertTrue(CFEqual(attributes.children[1],second))
    }
    private func results(_ fields: [String: AnyObject]) -> CFArray {
        AccessibilitySnapshotAttributes.names.map { fields[$0] ?? NSNull() } as CFArray
    }

    func testUnsupportedFieldDoesNotDiscardOtherFields() throws {
        var error = AXError.attributeUnsupported
        let encodedError = try XCTUnwrap(AXValueCreate(.axError, &error))
        let attributes = try AccessibilitySnapshotAttributes(results: self.results([
            "AXRole": "AXButton" as NSString,
            "AXTitle": "Play: 日本語\n'quoted'" as NSString,
            "AXSubrole": encodedError,
            "AXEnabled": NSNumber(value: false),
            "AXFocused": NSNumber(value: true),
        ]))
        XCTAssertEqual(attributes.string("AXTitle"), "Play: 日本語\n'quoted'")
        XCTAssertEqual(attributes.string("AXRole"), "AXButton")
        XCTAssertNil(attributes.string("AXSubrole"))
        XCTAssertEqual(attributes.errors["AXSubrole"], .attributeUnsupported)
        XCTAssertEqual(attributes.errors["AXSelected"], .noValue)
        XCTAssertEqual(attributes.boolean("AXEnabled"), false)
        XCTAssertEqual(attributes.boolean("AXFocused"), true)
        XCTAssertNil(attributes.boolean("AXSelected"))
    }

    func testFrameAndChildrenKeepNativeTypes() throws {
        var point = CGPoint(x: -120.5, y: 45.25)
        var size = CGSize(width: 300, height: 200)
        let child = AXUIElementCreateApplication(123)
        let attributes = try AccessibilitySnapshotAttributes(results: self.results([
            "AXPosition": try XCTUnwrap(AXValueCreate(.cgPoint, &point)),
            "AXSize": try XCTUnwrap(AXValueCreate(.cgSize, &size)),
            "AXChildren": [child, "invalid child" as NSString] as NSArray,
        ]))
        XCTAssertEqual(attributes.frame, CGRect(origin: point, size: size))
        XCTAssertEqual(attributes.children.count, 1)
        XCTAssertTrue(CFEqual(attributes.children.first, child))
    }

    func testWrongTypesAreNotPresentedAsValidGeometry() throws {
        let attributes = try AccessibilitySnapshotAttributes(results: self.results([
            "AXPosition": "not a point" as NSString,
            "AXSize": NSNumber(value: 200),
            "AXChildren": "not children" as NSString,
        ]))
        XCTAssertNil(attributes.frame)
        XCTAssertTrue(attributes.children.isEmpty)
    }

    func testMismatchedCountFailsInsteadOfShiftingFieldNames() {
        XCTAssertThrowsError(try AccessibilitySnapshotAttributes(results: ["AXButton"] as CFArray))
    }
    func testSelectionAndNumericValuesKeepTheirTypes() throws {
        var range = CFRange(location: 1, length: 2)
        let attributes = try AccessibilitySnapshotAttributes(results: self.results(["AXSelectedTextRange": try XCTUnwrap(AXValueCreate(.cfRange, &range)), "AXValue":NSNumber(value:0.25)]))
        XCTAssertEqual(attributes.selectedRange?.location, 1); XCTAssertEqual(attributes.selectedRange?.length, 2)
        let json = try JSONEncoder().encode(AccessibilityControlValue(attributes.values["AXValue"]))
        XCTAssertEqual(String(data:json,encoding:.utf8), "0.25")
    }
    func testUnselectedCollectionItemRetainsSemanticContainer() throws {
        let selected = try AccessibilitySnapshotAttributes(results:self.results(["AXSelected":NSNumber(value:false)]))
        let inert = try AccessibilitySnapshotAttributes(results:self.results([:]))
        XCTAssertTrue(selected.hasControlState); XCTAssertFalse(inert.hasControlState)
    }
    func testPerAttributeStaleAndMessagingFailuresCannotLookLikeMissingContent() throws {
        for code in [AXError.invalidUIElement, .cannotComplete, .apiDisabled] {
            var error = code
            let value = try XCTUnwrap(AXValueCreate(.axError, &error))
            XCTAssertThrowsError(try AccessibilitySnapshotAttributes(results: self.results([
                "AXRole": "AXGroup" as NSString, "AXChildren": value,
            ])))
        }
    }

}
