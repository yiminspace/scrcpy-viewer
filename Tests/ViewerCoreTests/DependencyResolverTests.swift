import Foundation
import XCTest
@testable import ViewerCore

final class DependencyResolverTests: XCTestCase {
    private var fixtureDirectory: URL!
    private let serverData = Data("synthetic scrcpy-server fixture 3.3.3\n".utf8)
    private let serverHash = "20aebc884d6f307c937037d4ebb27d2bf3b8483fd86ddb821295415c0427cabf"
    private var home: URL { fixtureDirectory.appendingPathComponent("isolated-home") }
    private var managed: URL { DependencyResolver.managedServerURL(homeDirectory: home) }
    private var desktop: URL { fixtureDirectory.appendingPathComponent("prefix/bin/scrcpy") }
    private var desktopServer: URL { fixtureDirectory.appendingPathComponent("prefix/share/scrcpy/scrcpy-server") }

    override func setUpWithError() throws {
        fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("scrcpy-viewer-dependencies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: fixtureDirectory) }

    func testExplicitVerifiedServerDoesNotRequireDesktopScrcpy() throws {
        var environment = try fixtureEnvironment(versionOutput: nil)
        let explicit = fixtureDirectory.appendingPathComponent("custom/server")
        try writeServer(to: explicit)
        environment["SCRCPY_SERVER_PATH"] = explicit.path
        let result = try resolve(environment)
        XCTAssertEqual(result.adbURL.path, environment["ADB"])
        XCTAssertEqual(result.serverURL, explicit)
        XCTAssertNil(result.scrcpyURL)
        XCTAssertEqual(result.serverVersion, "3.3.3")
    }

    func testCompatibleDesktopServerIsPreferredOverManagedCopy() throws {
        let environment = try fixtureEnvironment()
        try writeServer(to: desktopServer)
        try writeServer(to: managed)
        let result = try resolve(environment)
        XCTAssertEqual(result.scrcpyURL, desktop)
        XCTAssertEqual(result.serverURL, desktopServer)
    }

    func testSymlinkedDesktopFindsItsMatchingServer() throws {
        var environment = try fixtureEnvironment(versionOutput: nil)
        let binary = fixtureDirectory.appendingPathComponent("cellar/scrcpy/3.3.3/bin/scrcpy")
        let server = fixtureDirectory.appendingPathComponent("cellar/scrcpy/3.3.3/share/scrcpy/scrcpy-server")
        try writeExecutable("#!/bin/sh\nprintf 'scrcpy 3.3.3\\n'\n", to: binary)
        try writeServer(to: server)
        try FileManager.default.createDirectory(at: desktop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: desktop, withDestinationURL: binary)
        environment["SCRCPY_BIN"] = desktop.path
        let result = try resolve(environment)
        XCTAssertEqual(result.serverURL.resolvingSymlinksInPath(), server.resolvingSymlinksInPath())
    }

    func testVerifiedManagedServerWorksWithoutDesktopScrcpy() throws {
        let environment = try fixtureEnvironment(versionOutput: nil)
        try writeServer(to: managed)
        let result = try resolve(environment)
        XCTAssertEqual(result.serverURL, managed)
        XCTAssertNil(result.scrcpyURL)
    }

    func testNewerDesktopDoesNotBlockVerifiedManagedServer() throws {
        let environment = try fixtureEnvironment(versionOutput: "scrcpy 9.0.0\n")
        try writeServer(to: desktopServer, data: Data("newer incompatible server".utf8))
        try writeServer(to: managed)
        let result = try resolve(environment)
        XCTAssertEqual(result.serverURL, managed)
        XCTAssertNil(result.scrcpyURL)
    }

    func testBrokenDesktopServerFallsBackToVerifiedManagedServer() throws {
        let environment = try fixtureEnvironment()
        try writeServer(to: desktopServer, data: Data("wrong server beside compatible CLI".utf8))
        try writeServer(to: managed)
        XCTAssertEqual(try resolve(environment).serverURL, managed)
    }

    func testManagedServerWithWrongHashIsRejected() throws {
        let environment = try fixtureEnvironment(versionOutput: nil)
        try writeServer(to: managed, data: Data("corrupt download".utf8))
        assertFails(environment, containing: "校验失败")
    }

    func testManagedServerUnderAnotherVersionIsNotSelected() throws {
        let environment = try fixtureEnvironment(versionOutput: nil)
        let other = managed.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("9.0.0/scrcpy-server")
        try writeServer(to: other)
        assertFails(environment, containing: "3.3.3")
    }

    func testMissingManagedAndDesktopServerExplainsPinnedInstallation() throws {
        let environment = try fixtureEnvironment(versionOutput: nil)
        XCTAssertThrowsError(try resolve(environment)) { error in
            XCTAssertTrue(error.localizedDescription.contains("setup-dependencies.sh"))
            XCTAssertFalse(error.localizedDescription.contains("brew install scrcpy"))
        }
    }

    func testWrongExplicitServerIsNotTrustedBecauseDesktopVersionMatches() throws {
        var environment = try fixtureEnvironment()
        try writeServer(to: desktopServer)
        try writeServer(to: managed)
        let explicit = fixtureDirectory.appendingPathComponent("explicit/wrong-server")
        try writeServer(to: explicit, data: Data("incompatible server".utf8))
        environment["SCRCPY_SERVER_PATH"] = explicit.path
        assertFails(environment, containing: "校验失败")
    }

    func testMissingExplicitServerDoesNotSilentlyUseManagedCopy() throws {
        var environment = try fixtureEnvironment(versionOutput: nil)
        try writeServer(to: managed)
        let missing = fixtureDirectory.appendingPathComponent("missing-server")
        environment["SCRCPY_SERVER_PATH"] = missing.path
        assertFails(environment, containing: missing.path)
    }

    func testRejectsUnsupportedDesktopWhenNoManagedServerExists() throws {
        let environment = try fixtureEnvironment(versionOutput: "scrcpy 9.0.0\n")
        assertFails(environment, containing: "9.0.0")
    }

    func testRejectsUnreadableDesktopVersionWithoutManagedServer() throws {
        let environment = try fixtureEnvironment(versionOutput: "")
        assertFails(environment, containing: "无法读取本机 scrcpy 版本")
    }

    func testCompatibleDesktopWithMismatchedServerIsRejected() throws {
        let environment = try fixtureEnvironment()
        try writeServer(to: desktopServer, data: Data("different release".utf8))
        assertFails(environment, containing: "校验失败")
    }

    func testMissingADBGivesPlatformToolsCommandWithoutReadingHostInstall() throws {
        var environment = try fixtureEnvironment(versionOutput: nil)
        environment.removeValue(forKey: "ADB")
        try writeServer(to: managed)
        assertFails(environment, containing: "brew install android-platform-tools")
    }

    func testRejectsExplicitMissingADBInsteadOfUsingHostBinary() throws {
        var environment = try fixtureEnvironment()
        let missingPath = fixtureDirectory.appendingPathComponent("missing-adb").path
        environment["ADB"] = missingPath
        assertFails(environment, containing: missingPath)
    }

    private func assertFails(_ environment: [String: String], containing text: String) {
        XCTAssertThrowsError(try resolve(environment)) { error in
            XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription)
        }
    }

    private func resolve(_ environment: [String: String]) throws -> ViewerDependencies {
        // No real user home, Homebrew fallback, or host PATH may affect these tests.
        try DependencyResolver.resolve(environment: environment, homeDirectory: home,
            fallbackBinaryDirectories: [], expectedServerSHA256: serverHash)
    }

    private func fixtureEnvironment(versionOutput: String? = "scrcpy 3.3.3\n") throws -> [String: String] {
        let adb = fixtureDirectory.appendingPathComponent("fixture-adb")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: adb)
        var environment = ["ADB": adb.path, "PATH": fixtureDirectory.appendingPathComponent("empty-bin").path]
        if let versionOutput {
            try writeExecutable("#!/bin/sh\n/bin/cat <<'FIXTURE_VERSION'\n\(versionOutput)FIXTURE_VERSION\n", to: desktop)
            environment["SCRCPY_BIN"] = desktop.path
        }
        return environment
    }

    private func writeServer(to url: URL, data: Data? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data ?? serverData).write(to: url)
    }

    private func writeExecutable(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
