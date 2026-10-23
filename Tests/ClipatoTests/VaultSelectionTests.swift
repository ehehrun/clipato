import AppKit
import XCTest
@testable import Clipato

final class VaultSelectionTests: XCTestCase {
    private let ids = (0..<6).map { _ in UUID() }

    func testDraggingSelectedCardExcludesHiddenAndDeletedSelection() {
        let selected: Set<UUID> = [ids[0], ids[1], ids[3], UUID()]
        let visible: Set<UUID> = [ids[0], ids[1], ids[2]]
        XCTAssertEqual(VaultSelection.draggedIDs(startingWith: ids[1], visibleIDs: visible, selected: selected), [ids[0], ids[1]])
    }

    func testDraggingUnselectedCardOnlyCarriesThatImage() {
        XCTAssertEqual(VaultSelection.draggedIDs(startingWith: ids[2], visibleIDs: Set(ids), selected: [ids[0], ids[1]]), [ids[2]])
    }

    func testShiftEndpointsSelectInclusiveRangeAndKeepOtherSelections() {
        var selection = VaultSelection()
        var selected: Set<UUID> = [ids[5]]
        selected = selection.select(ids[1], in: ids, modifiers: [.shift], selected: selected)
        selected = selection.select(ids[3], in: ids, modifiers: [.shift], selected: selected)
        XCTAssertEqual(selected, Set([ids[1], ids[2], ids[3], ids[5]]))
        XCTAssertEqual(selection.anchor, ids[1])
    }

    func testOrdinaryClickSetsAnchorAndReverseShiftClickIncludesBothEnds() {
        var selection = VaultSelection()
        let selected = selection.select(ids[4], in: ids, modifiers: [], selected: [])
        let range = selection.select(ids[1], in: ids, modifiers: [.shift], selected: selected)
        XCTAssertEqual(range, Set(ids[1...4]))
        XCTAssertEqual(selection.anchor, ids[4])
    }

    func testRepeatedRangeUsesOriginalAnchorAndDoesNotToggleSelectedImages() {
        var selection = VaultSelection()
        var selected = selection.select(ids[2], in: ids, modifiers: [], selected: [])
        selected = selection.select(ids[4], in: ids, modifiers: [.shift], selected: selected)
        selected = selection.select(ids[0], in: ids, modifiers: [.shift], selected: selected)
        XCTAssertEqual(selected, Set(ids[0...4]))
        XCTAssertEqual(selection.anchor, ids[2])
    }

    func testOrdinaryClickReplacesSelectionAndEstablishesNewRangeAnchor() {
        var selection = VaultSelection()
        var selected = selection.select(ids[1], in: ids, modifiers: [], selected: [ids[1], ids[5]])
        XCTAssertEqual(selected, [ids[1]])
        selected = selection.select(ids[3], in: ids, modifiers: [.shift], selected: selected)
        XCTAssertEqual(selected, Set(ids[1...3]))
        selected = selection.select(ids[4], in: ids, modifiers: [], selected: selected)
        XCTAssertEqual(selected, [ids[4]])
        selected = selection.select(ids[4], in: ids, modifiers: [], selected: selected)
        XCTAssertEqual(selected, [ids[4]])
        XCTAssertEqual(selection.anchor, ids[4])
    }

    func testRangeFollowsFilteredOrderWithoutSelectingHiddenImages() {
        var selection = VaultSelection()
        let filtered = [ids[4], ids[1], ids[3]]
        var selected = selection.select(ids[4], in: filtered, modifiers: [], selected: [ids[0]])
        selected = selection.select(ids[3], in: filtered, modifiers: [.shift], selected: selected)
        XCTAssertEqual(selected, Set(filtered))
        XCTAssertFalse(selected.contains(ids[2]))
    }

    func testRemovedAnchorStartsNewRangeWithoutSelectingUnrelatedImages() {
        var selection = VaultSelection(anchor: ids[2])
        let remaining = [ids[0], ids[1], ids[3], ids[4], ids[5]]
        let selected = selection.select(ids[4], in: remaining, modifiers: [.shift], selected: [ids[0]])
        XCTAssertEqual(selected, [ids[0], ids[4]])
        XCTAssertEqual(selection.anchor, ids[4])
    }

    func testResetAnchorAfterSearchOrMarqueeStartsNewRangeEvenOnSelectedEndpoint() {
        var selection = VaultSelection(anchor: ids[0])
        selection.anchor = nil
        let selected = selection.select(ids[4], in: ids, modifiers: [.shift], selected: [ids[4], ids[5]])
        XCTAssertEqual(selected, [ids[4], ids[5]])
        XCTAssertEqual(selection.anchor, ids[4])
    }

    func testCommandClickTogglesOnlyThatImageAndUpdatesRangeAnchor() {
        var selection = VaultSelection(anchor: ids[0])
        var selected = selection.select(ids[4], in: ids, modifiers: [.command], selected: [ids[0]])
        XCTAssertEqual(selected, [ids[0], ids[4]])
        XCTAssertEqual(selection.anchor, ids[4])
        selected = selection.select(ids[4], in: ids, modifiers: [.command], selected: selected)
        XCTAssertEqual(selected, [ids[0]])
        XCTAssertEqual(selection.anchor, ids[4])
        selected = selection.select(ids[2], in: ids, modifiers: [.shift], selected: selected)
        XCTAssertEqual(selected, [ids[0], ids[2], ids[3], ids[4]])
    }

    func testCommandShiftClickStillExtendsInclusiveRange() {
        var selection = VaultSelection(anchor: ids[4])
        let selected = selection.select(ids[1], in: ids, modifiers: [.command, .shift], selected: [ids[5]])
        XCTAssertEqual(selected, Set(ids[1...5]))
        XCTAssertEqual(selection.anchor, ids[4])
    }

    func testCollectionRangeFollowsVisibleMixedAssetOrderAndCommandOnlyTogglesOne() {
        let image = CollectionAsset.image(ids[0])
        let hiddenImage = CollectionAsset.image(ids[1])
        let video = CollectionAsset.video(URL(fileURLWithPath: "/tmp/selection-video.mp4"))
        let session = CollectionAsset.session(ids[2])
        let visible = [session, image, video]
        var anchor: CollectionAsset?
        var selected = VaultSelection.select(session, in: visible, modifiers: [], anchor: &anchor, selected: [])
        selected = VaultSelection.select(video, in: visible, modifiers: [.command], anchor: &anchor, selected: selected)
        XCTAssertEqual(selected, [session, video])
        XCTAssertFalse(selected.contains(image))
        selected = VaultSelection.select(session, in: visible, modifiers: [.shift], anchor: &anchor, selected: selected)
        XCTAssertEqual(selected, Set(visible))
        XCTAssertFalse(selected.contains(hiddenImage))
        selected = VaultSelection.select(image, in: visible, modifiers: [.command], anchor: &anchor, selected: selected)
        XCTAssertEqual(selected, [session, video])
        selected = VaultSelection.select(video, in: visible, modifiers: [], anchor: &anchor, selected: selected)
        XCTAssertEqual(selected, [video])
        XCTAssertEqual(anchor, video)
    }

    func testKeyframeShiftRangeUsesSameRulesAndRetainsOtherFrames() {
        let frames = Array(0..<8)
        var anchor: Int?
        var selected = VaultSelection.select(1, in: frames, modifiers: [.command], anchor: &anchor, selected: [7])
        selected = VaultSelection.select(4, in: frames, modifiers: [.shift], anchor: &anchor, selected: selected)
        XCTAssertEqual(selected, [1, 2, 3, 4, 7])
        selected = VaultSelection.select(3, in: frames, modifiers: [.command], anchor: &anchor, selected: selected)
        XCTAssertEqual(selected, [1, 2, 4, 7])
        XCTAssertEqual(anchor, 3)
    }

    func testPreviewPrefersMostRecentVisibleSelectionOverEarlierSelectedImage() {
        XCTAssertEqual(VaultSelection.previewID(in: ids, selected: [ids[0], ids[3]], preferredID: ids[3]), ids[3])
    }

    func testPreviewUsesFilteredOrderWhenPreferredImageIsHiddenOrDeselected() {
        let visible = [ids[4], ids[1], ids[3]]
        let selected: Set<UUID> = [ids[0], ids[1], ids[4]]
        XCTAssertEqual(VaultSelection.previewID(in: visible, selected: selected, preferredID: ids[0]), ids[4])
        XCTAssertEqual(VaultSelection.previewID(in: visible, selected: selected, preferredID: ids[3]), ids[4])
        XCTAssertEqual(VaultSelection.previewID(in: visible, selected: selected, preferredID: nil), ids[4])
    }

    func testPreviewDoesNotInventSelectionForEmptyOrEntirelyHiddenSelection() {
        XCTAssertNil(VaultSelection.previewID(in: ids, selected: [], preferredID: ids[0]))
        XCTAssertNil(VaultSelection.previewID(in: [ids[2], ids[3]], selected: [ids[0]], preferredID: ids[0]))
        XCTAssertNil(VaultSelection.previewID(in: [], selected: [ids[0]], preferredID: ids[0]))
    }

}
