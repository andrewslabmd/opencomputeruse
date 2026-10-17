import AppKit
import ApplicationServices
import XCTest
@testable import ComputerUseHelper

final class AccessibilitySelectionStyleTests: XCTestCase {
    func testUnderlineAndStrikethroughKeepExactRunsAndExplicitFalse() throws {
        let text = NSMutableAttributedString(string: "Plain marked")
        let underline = NSAttributedString.Key(rawValue: kAXUnderlineTextAttribute.takeUnretainedValue() as String)
        let strike = NSAttributedString.Key(rawValue: kAXStrikethroughTextAttribute.takeUnretainedValue() as String)
        text.addAttribute(underline, value: NSNumber(value: 0), range: NSRange(location: 0, length: 6))
        text.addAttribute(underline, value: NSNumber(value: 1), range: NSRange(location: 6, length: 6))
        text.addAttribute(strike, value: NSNumber(value: 1), range: NSRange(location: 6, length: 6))
        let runs = try XCTUnwrap(AccessibilitySelectionStyle.runs(text, offset: 31))
        XCTAssertEqual(runs.map(\.location), [31, 37]); XCTAssertEqual(runs.map(\.length), [6, 6])
        XCTAssertEqual(runs.map(\.underline), [false, true]); XCTAssertEqual(runs.map(\.strikethrough), [nil, true])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(runs)) as? [[String: Any]])
        XCTAssertEqual(object[1]["underline"] as? Bool, true)
    }
    func testMissingStyleIsUnknownAndTooManyRunsDoNotPresentPartialCoverage() {
        XCTAssertNil(AccessibilitySelectionStyle.runs(NSAttributedString(string: "x"), offset: 0)?.first?.underline)
        let text = NSMutableAttributedString(string: String(repeating: "x", count: 33))
        for i in 0..<33 { text.addAttribute(.init("AXUnderline"), value: NSNumber(value: i % 2), range: NSRange(location: i, length: 1)) }
        XCTAssertNil(AccessibilitySelectionStyle.runs(text, offset: 0))
    }
}
