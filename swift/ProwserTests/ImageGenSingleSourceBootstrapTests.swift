import XCTest
@testable import Prowser

final class ImageGenSingleSourceBootstrapTests: XCTestCase {
    private func touch(_ name: String, in dir: URL) -> String {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url.path
    }

    func testPrefersLockedPathOverActiveWhenNotForcing() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = ImageGenSingleSourceBootstrap.Input(
            forceFromActive: false,
            lockedPath: touch("locked.png", in: dir),
            valuePath: touch("values.png", in: dir),
            restoredLastDialogPath: touch("restored.png", in: dir),
            activePath: touch("active.png", in: dir)
        )
        XCTAssertEqual(ImageGenSingleSourceBootstrap.resolve(input).path, input.lockedPath)
    }

    func testForceFromActiveWinsOverLocked() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let active = touch("active.png", in: dir)
        let input = ImageGenSingleSourceBootstrap.Input(
            forceFromActive: true,
            lockedPath: touch("locked.png", in: dir),
            valuePath: nil,
            restoredLastDialogPath: nil,
            activePath: active
        )
        XCTAssertEqual(ImageGenSingleSourceBootstrap.resolve(input).path, active)
    }

    func testRestoredLastDialogUsedWhenNoLockedOrValues() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let restored = touch("restored.png", in: dir)
        let input = ImageGenSingleSourceBootstrap.Input(
            forceFromActive: false,
            lockedPath: nil,
            valuePath: nil,
            restoredLastDialogPath: restored,
            activePath: touch("active.png", in: dir)
        )
        XCTAssertEqual(ImageGenSingleSourceBootstrap.resolve(input).path, restored)
    }

    func testPlainLastSettingsRequestDetection() {
        let plain = ImageGenDialogRequest(
            function: "expand",
            replaceJobID: nil,
            initialPrompt: nil,
            autoImportEXIF: false,
            autoGenerate: false,
            editSourcePaths: [],
            openWithLastSettings: true,
            primeSourceFromActiveImage: false
        )
        XCTAssertTrue(plain.isPlainLastSettingsOpen)

        let fast = ImageGenDialogRequest(
            function: "expand",
            replaceJobID: nil,
            initialPrompt: "hi",
            autoImportEXIF: true,
            autoGenerate: false,
            editSourcePaths: [],
            openWithLastSettings: false,
            primeSourceFromActiveImage: true
        )
        XCTAssertFalse(fast.isPlainLastSettingsOpen)
    }
}
