import Foundation
import CryptoKit

public enum DependencyResolver {
    public static let supportedServerVersion = "3.3.3"
    // Official release asset and SHA256SUMS.txt, also verified against the GitHub asset digest:
    // https://github.com/Genymobile/scrcpy/releases/tag/v3.3.3
    public static let supportedServerSHA256 = "7e70323ba7f259649dd4acce97ac4fefbae8102b2c6d91e2e7be613fd5354be0"

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ViewerDependencies {
        try resolve(environment: environment, homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                    fallbackBinaryDirectories: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"],
                    expectedServerSHA256: supportedServerSHA256)
    }

    public static func managedServerURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/Scrcpy Viewer/Dependencies/scrcpy")
            .appendingPathComponent(supportedServerVersion).appendingPathComponent("scrcpy-server")
    }

    // Tests supply isolated locations and a synthetic artifact hash; production always uses
    // the public entry point above and the pinned official release hash, with no network access.
    static func resolve(environment: [String: String], homeDirectory: URL,
                        fallbackBinaryDirectories: [String], expectedServerSHA256: String) throws -> ViewerDependencies {
        let adb = try binary("adb", override: environment["ADB"], environment: environment,
                             fallbackDirectories: fallbackBinaryDirectories)
        if let path = environment["SCRCPY_SERVER_PATH"], !path.isEmpty {
            let server = URL(fileURLWithPath: path)
            // An explicit override must fail clearly if it is wrong, rather than silently
            // selecting another server or trusting the version of an unrelated desktop CLI.
            try validate(server, expectedSHA256: expectedServerSHA256)
            return ViewerDependencies(adbURL: adb, serverURL: server, serverVersion: supportedServerVersion)
        }

        var desktopIssue: String?
        do {
            let scrcpy = try binary("scrcpy", override: environment["SCRCPY_BIN"], environment: environment,
                                    fallbackDirectories: fallbackBinaryDirectories)
            let versionText = try CommandRunner.checked(executable: scrcpy, arguments: ["--version"], timeout: 5)
            let parts = versionText.split(whereSeparator: \.isNewline).first?.split(whereSeparator: \.isWhitespace) ?? []
            guard parts.count >= 2, parts[0] == "scrcpy" else {
                throw ViewerError.message("无法读取本机 scrcpy 版本。")
            }
            guard parts[1] == supportedServerVersion else {
                throw ViewerError.message("本机 scrcpy \(parts[1]) 的 server 不兼容；需要 \(supportedServerVersion)。")
            }
            let candidates = [scrcpy, scrcpy.resolvingSymlinksInPath()].map {
                $0.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("share/scrcpy/scrcpy-server")
            }
            for candidate in candidates where FileManager.default.isReadableFile(atPath: candidate.path) {
                do {
                    try validate(candidate, expectedSHA256: expectedServerSHA256)
                    return ViewerDependencies(adbURL: adb, scrcpyURL: scrcpy, serverURL: candidate, serverVersion: supportedServerVersion)
                } catch { desktopIssue = error.localizedDescription }
            }
            if desktopIssue == nil { desktopIssue = "本机 scrcpy \(supportedServerVersion) 缺少配套 server。" }
        } catch { desktopIssue = error.localizedDescription }

        let managed = managedServerURL(homeDirectory: homeDirectory)
        if FileManager.default.fileExists(atPath: managed.path) {
            try validate(managed, expectedSHA256: expectedServerSHA256)
            return ViewerDependencies(adbURL: adb, serverURL: managed, serverVersion: supportedServerVersion)
        }
        throw ViewerError.message("\(desktopIssue ?? "未找到兼容的 scrcpy-server。")\n\(installationHint)")
    }

    private static let installationHint = "请运行随应用提供的 setup-dependencies.sh，安装官方 scrcpy-server 3.3.3；无需安装或降级桌面 scrcpy。"

    private static func validate(_ server: URL, expectedSHA256: String) throws {
        guard FileManager.default.isReadableFile(atPath: server.path) else {
            throw ViewerError.message("找不到或无法读取 scrcpy-server：\(server.path)\n\(installationHint)")
        }
        let actual: String
        do {
            let file = try FileHandle(forReadingFrom: server)
            defer { try? file.close() }
            var hash = SHA256()
            while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
            actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            throw ViewerError.message("无法读取 scrcpy-server：\(server.path)\n\(installationHint)")
        }
        guard actual == expectedSHA256 else {
            throw ViewerError.message("scrcpy-server 校验失败，需要官方 \(supportedServerVersion) 文件：\(server.path)\n\(installationHint)")
        }
    }

    private static func binary(_ name: String, override: String?, environment: [String: String], fallbackDirectories: [String]) throws -> URL {
        if let override, !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else { throw ViewerError.message("\(name) 路径不可执行：\(override)") }
            return URL(fileURLWithPath: override)
        }
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + fallbackDirectories
        for directory in directories where !directory.isEmpty {
            let file = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: file.path) { return file }
        }
        if name == "adb" { throw ViewerError.message("未安装 adb。请运行 brew install android-platform-tools，然后重新检查。") }
        throw ViewerError.message("未找到桌面 scrcpy。")
    }
}
