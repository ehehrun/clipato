import Foundation
import XCTest
@testable import Clipato

final class AssetTagTests: XCTestCase {
    func testTagFiltersSeparateUntaggedAndEveryColor() {
        XCTAssertTrue(AssetTagFilter.all.includes(nil))
        XCTAssertTrue(AssetTagFilter.untagged.includes(nil))
        for tag in AssetTag.allCases {
            XCTAssertTrue(AssetTagFilter.all.includes(tag))
            XCTAssertFalse(AssetTagFilter.untagged.includes(tag))
            XCTAssertTrue(AssetTagFilter.tag(tag).includes(tag))
            XCTAssertFalse(AssetTagFilter.tag(tag).includes(nil))
            for other in AssetTag.allCases where other != tag {
                XCTAssertFalse(AssetTagFilter.tag(tag).includes(other))
            }
        }
    }

    func testStoredColorNamesRoundTripWithoutChangingFields() throws {
        let expected = "[\"red\",\"orange\",\"yellow\",\"green\",\"blue\",\"purple\",\"gray\"]"
        let encoded = try JSONEncoder().encode(AssetTag.allCases)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), expected)
        XCTAssertEqual(try JSONDecoder().decode([AssetTag].self, from: encoded), AssetTag.allCases)
    }

    func testShiftRangeUsesFilteredSizeOrder() {
        let ids = (0..<5).map { _ in UUID() }
        let tags: [AssetTag?] = [.red, .blue, .red, nil, .red]
        let bytes: [Int64] = [500, 300, 100, 200, 400]
        let visible = AssetSortOrder.sizeAscending.sorted(ids.indices.filter { AssetTagFilter.tag(.red).includes(tags[$0]) }, date: { _ in nil }, size: { bytes[$0] }, name: { String($0) })
            .map { ids[$0] }
        XCTAssertEqual(visible, [ids[2], ids[4], ids[0]])
        var selection = VaultSelection()
        let first = selection.select(ids[2], in: visible, modifiers: [], selected: [])
        let range = selection.select(ids[0], in: visible, modifiers: [.shift], selected: first)
        XCTAssertEqual(range, [ids[0], ids[2], ids[4]])
    }
}
