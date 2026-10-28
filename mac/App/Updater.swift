import AppKit
import Foundation

/// Checks GitHub Releases for a newer Vircam once a day. Nothing is downloaded until the
/// user picks "Update"; then the release's Vircam.dmg replaces this app and it relaunches.
@MainActor
final class Updater: ObservableObject {
    struct Release {
        let version: String
        let dmgURL: URL
    }

    @Published private(set) var available: Release?
    @Published private(set) var status: String?

    static let repository = "rAlexander89/vircam"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let lastCheckKey = "lastUpdateCheck"

    private var timer: Timer?
    private var installing = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        checkIfDue()
        // Hourly ticks so a check still happens about a day later after the Mac sleeps.
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= Self.checkInterval {
            Task { await check() }
        }
    }

    func check() async {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard Self.isVersion(version, newerThan: currentVersion),
                  let asset = release.assets.first(where: { $0.name == "Vircam.dmg" }),
                  let url = URL(string: asset.browser_download_url),
                  url.scheme == "https" else {
                available = nil
                return
            }
            available = Release(version: version, dmgURL: url)
        } catch {
            // Offline or rate limited; the next hourly tick retries.
        }
    }

    func install() {
        guard let available, !installing else { return }
        installing = true
        status = "Downloading Vircam \(available.version)…"
        Task {
            do {
                let staged = try await Self.download(available)
                status = "Restarting Vircam…"
                try Self.replace(appAt: Bundle.main.bundlePath, with: staged)
                NSApp.terminate(nil)
            } catch {
                status = "Update failed: \(error.localizedDescription)"
                installing = false
            }
        }
    }

    /// Downloads and mounts the DMG, and copies its Vircam.app to a staging folder.
    private nonisolated static func download(_ release: Release) async throws -> URL {
        let (dmg, _) = try await URLSession.shared.download(from: release.dmgURL)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("vircam-update-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mount")
        let staged = work.appendingPathComponent("Vircam.app")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        try run("/usr/bin/ditto", [mount.appendingPathComponent("Vircam.app").path, staged.path])

        let bundle = Bundle(url: staged)
        guard bundle?.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version else {
            throw UpdateError.unexpectedApp
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", staged.path])
        return staged
    }

    /// Swaps the app in place after this process exits, then opens the new version.
    private static func replace(appAt destination: String, with staged: URL) throws {
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            rm -rf "$2" && ditto "$3" "$2" && xattr -dr com.apple.quarantine "$2"
            open "$2"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                             destination, staged.path]
        try process.run()
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw UpdateError.toolFailed(URL(fileURLWithPath: tool).lastPathComponent)
        }
    }

    /// Compares dotted numeric versions, e.g. "0.10.0" > "0.9.2".
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private enum UpdateError: LocalizedError {
        case unexpectedApp
        case toolFailed(String)

        var errorDescription: String? {
            switch self {
            case .unexpectedApp: return "The download did not contain the expected Vircam version."
            case .toolFailed(let tool): return "\(tool) failed."
            }
        }
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }

    let tag_name: String
    let assets: [Asset]
}
