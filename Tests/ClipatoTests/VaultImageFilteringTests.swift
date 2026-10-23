import Foundation
import XCTest
@testable import Clipato

final class VaultImageFilteringTests: XCTestCase {
    private let bannerID = UUID()
    private let productID = UUID()
    private let captureID = UUID()
    private let receiptID = UUID()
    private let referenceID = UUID()
    private let workCollectionID = UUID()
    private let referenceCollectionID = UUID()

    func testAllImagesRetainTheirInputOrderAndOriginalFields() {
        let images = fixtureImages()

        let result = matchingVaultImages(images, query: "", collectionFilter: .all,
                                         tagFilter: .all, collectionMembers: collectionMembers)

        XCTAssertEqual(result.map(\.id), [bannerID, productID, captureID, receiptID, referenceID])
        XCTAssertEqual(result, images)
    }

    func testQueryMatchesFilenameOrSourceWithoutCaseSensitivity() {
        let images = fixtureImages()

        XCTAssertEqual(matchingVaultImages(images, query: "pROdUCt", collectionFilter: .all,
                                            tagFilter: .all, collectionMembers: collectionMembers).map(\.id),
                       [productID])
        XCTAssertEqual(matchingVaultImages(images, query: "wEb", collectionFilter: .all,
                                            tagFilter: .all, collectionMembers: collectionMembers).map(\.id),
                       [bannerID, productID, referenceID])
        XCTAssertEqual(matchingVaultImages(images, query: "iMPoRT", collectionFilter: .all,
                                            tagFilter: .all, collectionMembers: collectionMembers).map(\.id),
                       [bannerID])
    }

    func testColorAndUntaggedFiltersKeepOnlyTheRequestedImages() {
        let images = fixtureImages()

        XCTAssertEqual(matchingVaultImages(images, query: "", collectionFilter: .all,
                                            tagFilter: .tag(.green), collectionMembers: collectionMembers).map(\.id),
                       [bannerID, productID])
        XCTAssertEqual(matchingVaultImages(images, query: "", collectionFilter: .all,
                                            tagFilter: .untagged, collectionMembers: collectionMembers).map(\.id),
                       [receiptID, referenceID])
    }

    func testUnfiledExcludesMembershipInAnyCollectionWithoutDuplicatingImages() {
        let result = matchingVaultImages(fixtureImages(), query: "", collectionFilter: .unfiled,
                                         tagFilter: .all, collectionMembers: collectionMembers)

        XCTAssertEqual(result.map(\.id), [bannerID, receiptID, referenceID])
        XCTAssertEqual(result.count, 3)
    }

    func testQueryCollectionAndTagConstraintsMustAllMatch() {
        let images = fixtureImages()

        XCTAssertEqual(matchingVaultImages(images, query: "WEB", collectionFilter: .unfiled,
                                            tagFilter: .untagged, collectionMembers: collectionMembers).map(\.id),
                       [referenceID])
        XCTAssertEqual(matchingVaultImages(images, query: "WEB", collectionFilter: .all,
                                            tagFilter: .tag(.green), collectionMembers: collectionMembers).map(\.id),
                       [bannerID, productID])
        XCTAssertEqual(matchingVaultImages(images, query: "WEB", collectionFilter: .unfiled,
                                            tagFilter: .tag(.green), collectionMembers: collectionMembers).map(\.id),
                       [bannerID])
        XCTAssertTrue(matchingVaultImages(images, query: "WEB", collectionFilter: .unfiled,
                                           tagFilter: .tag(.purple), collectionMembers: collectionMembers).isEmpty)
    }

    func testEmptyInputAndUnmatchedQueriesOrTagsReturnNoImages() {
        let images = fixtureImages()

        XCTAssertTrue(matchingVaultImages([], query: "", collectionFilter: .all,
                                           tagFilter: .all, collectionMembers: collectionMembers).isEmpty)
        XCTAssertTrue(matchingVaultImages(images, query: "not-in-this-library", collectionFilter: .all,
                                           tagFilter: .all, collectionMembers: collectionMembers).isEmpty)
        XCTAssertTrue(matchingVaultImages(images, query: "", collectionFilter: .all,
                                           tagFilter: .tag(.orange), collectionMembers: collectionMembers).isEmpty)
    }

    private var collectionMembers: [UUID: Set<CollectionAsset>] {
        [workCollectionID: [.image(productID), .session(receiptID)],
         referenceCollectionID: [.image(productID), .image(captureID),
                                 .video(URL(fileURLWithPath: "/tmp/Reference.mp4"))]]
    }

    private func fixtureImages() -> [VaultImage] {
        [VaultImage(id: bannerID, filename: "Banner.webp", createdAt: Date(timeIntervalSince1970: 300),
                    width: 1600, height: 900, source: "标注 Import", directory: nil, tag: .green),
         VaultImage(id: productID, filename: "Product-01.PNG", createdAt: Date(timeIntervalSince1970: 500),
                    width: 4096, height: 4096, source: "导入 Web", directory: URL(fileURLWithPath: "/tmp/Product", isDirectory: true), tag: .green),
         VaultImage(id: captureID, filename: "Capture.png", createdAt: Date(timeIntervalSince1970: 100),
                    width: 5120, height: 2880, source: "截图", directory: nil, tag: .purple),
         VaultImage(id: receiptID, filename: "Receipt.jpeg", createdAt: Date(timeIntervalSince1970: 400),
                    width: 600, height: 1200, source: "截图", directory: nil, tag: nil),
         VaultImage(id: referenceID, filename: "参考素材.PNG", createdAt: Date(timeIntervalSince1970: 200),
                    width: 960, height: 640, source: "收藏素材 Web", directory: URL(fileURLWithPath: "/tmp/Reference", isDirectory: true), tag: nil)]
    }
}
