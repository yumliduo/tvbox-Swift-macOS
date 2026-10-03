import XCTest
@testable import TVBox

final class SourceDanmakuTests: XCTestCase {
    func testParsesStandardPlayerSourcesAndScopesMediaHeaders() throws {
        let mediaURL = try XCTUnwrap(URL(string: "https://media.example/video.m3u8"))
        let result = SourceDanmakuParser.parse(from: ["danmaku": [
            ["name": "同源", "url": "https://media.example/episode.xml"],
            ["name": "跨域", "url": "https://comments.example/episode.xml"]
        ]], mediaURL: mediaURL, mediaHeaders: ["Authorization": "Bearer media"])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].headers["Authorization"], "Bearer media")
        XCTAssertNil(result[1].headers["Authorization"])
    }

    func testParsesBilibiliXMLModesColorsAndTimes() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><i>
        <d p="1.5,1,25,16711680,0,0,0,0">滚动</d>
        <d p="2.0,5,30,65280,0,0,0,0">顶部</d>
        <d p="3.0,4,20,255,0,0,0,0">底部</d>
        </i>
        """
        let result = try SourceDanmakuLoader.parse(data: Data(xml.utf8))

        XCTAssertEqual(result.map(\.time), [1.5, 2, 3])
        XCTAssertEqual(result.map(\.position), [.scrolling, .top, .bottom])
        XCTAssertEqual(result.map(\.color), [0xFF0000, 0x00FF00, 0x0000FF])
    }

    func testParsesDPlayerAndObjectJSON() throws {
        let json = """
        [
          [1.25, 0, "#ffffff", "数组弹幕"],
          {"progress":2500,"mode":5,"color":16776960,"content":"对象弹幕"}
        ]
        """
        let result = try SourceDanmakuLoader.parse(data: Data(json.utf8))

        XCTAssertEqual(result.map(\.time), [1.25, 2.5])
        XCTAssertEqual(result[1].position, .top)
        XCTAssertEqual(result[1].text, "对象弹幕")
    }
}
