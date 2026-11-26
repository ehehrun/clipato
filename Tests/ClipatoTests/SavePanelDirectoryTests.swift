import Foundation
import XCTest
@testable import Clipato

final class SavePanelDirectoryTests: XCTestCase {
    func testNoDirectoryIsChosenUntilTheUserConfirmsASaveDestination() throws {
        let (_, defaults) = try makeDefaults()
        XCTAssertNil(SavePanelDirectory.lastDirectory(defaults: defaults))
    }

    func testFileAndDirectoryExportsShareTheMostRecentDestinationAcrossInstances() throws {
        let (name, defaults) = try makeDefaults()
        let screenshot = URL(fileURLWithPath: "/Users/example/Pictures/截图保存/selection.png")
        SavePanelDirectory.rememberFile(screenshot, defaults: defaults)
        XCTAssertEqual(SavePanelDirectory.lastDirectory(defaults: defaults)?.path, screenshot.deletingLastPathComponent().path)

        let exportDirectory = URL(fileURLWithPath: "/Users/example/Documents/Export Folder", isDirectory: true)
        SavePanelDirectory.rememberDirectory(exportDirectory, defaults: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: name))
        XCTAssertEqual(SavePanelDirectory.lastDirectory(defaults: reopened)?.path, exportDirectory.path)

        let gif = URL(fileURLWithPath: "/Users/example/Desktop/演示.gif")
        SavePanelDirectory.rememberFile(gif, defaults: reopened)
        XCTAssertEqual(SavePanelDirectory.lastDirectory(defaults: defaults)?.path, gif.deletingLastPathComponent().path)
    }

    func testRememberingNavigationDoesNotRequireFilesystemAccessOrCreateDirectories() throws {
        let (_, defaults) = try makeDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clipato-SaveDestination-\(UUID().uuidString)", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        SavePanelDirectory.rememberDirectory(directory, defaults: defaults)

        XCTAssertEqual(SavePanelDirectory.lastDirectory(defaults: defaults)?.path, directory.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func makeDefaults() throws -> (String, UserDefaults) {
        let name = "Clipato.SavePanelDirectoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (name, defaults)
    }
}
