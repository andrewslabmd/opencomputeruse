import XCTest
import OCUStream

final class StreamWatchersTests: XCTestCase {
    func testRowTextShowsEveryNameTheHelperSendsDeduplicated() {
        // The helper already leaves out the app's own connection (by process), so a client
        // that merely calls itself "Open Computer Use" is still shown.
        XCTAssertNil(StreamWatchers.rowText([]))
        XCTAssertEqual(StreamWatchers.rowText(["Open Computer Use"]), "Watched by Open Computer Use")
        XCTAssertEqual(StreamWatchers.rowText(["botfactory", "botfactory"]), "Watched by botfactory")
        XCTAssertEqual(StreamWatchers.rowText(["Quest", "botfactory"]), "Watched by Quest, botfactory")
    }
    func testWatchersAreAnAdditiveProtocolV1Field() throws {
        let old = Data(#"{"agent":"a","name":"Agent","color_slot":0,"app_name":"Fixture","busy":false,"state":"live"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(StreamAgent.self, from: old).watchers, [])
        var agent = try JSONDecoder().decode(StreamAgent.self, from: old)
        agent.watchers = ["botfactory"]
        let encoded = try JSONEncoder().encode(agent)
        XCTAssertEqual(try JSONDecoder().decode(StreamAgent.self, from: encoded), agent)
        struct LegacyAgent: Decodable { let agent: String; let name: String; let state: StreamTargetState }
        XCTAssertEqual(try JSONDecoder().decode(LegacyAgent.self, from: encoded).name, "Agent")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json["future_field"] = true
        XCTAssertEqual(try JSONDecoder().decode(StreamAgent.self, from: JSONSerialization.data(withJSONObject: json)), agent)
    }
}
