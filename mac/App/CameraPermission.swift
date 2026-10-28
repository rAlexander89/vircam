import AppKit
import Foundation

/// Grants camera access for builds without a paid Apple signature. macOS never shows the
/// camera prompt for those, so Vircam writes the permission to the user's TCC database
/// itself, using the standard macOS administrator prompt (Vircam never sees the password).
/// Works only on Macs with SIP disabled, which unsigned Vircam requires anyway.
enum CameraPermission {
    private static let promptedKey = "cameraGrantPromptedFor"

    /// Whether the automatic prompt already ran for this exact build, so a user who
    /// cancels isn't asked again on every launch. The button always works.
    static var alreadyPromptedForThisBuild: Bool {
        UserDefaults.standard.string(forKey: promptedKey) == buildIdentity
    }

    /// Asks for the administrator password, writes the permission, and relaunches Vircam
    /// so the camera picks it up. Returns an error message if it didn't work.
    @MainActor
    static func grantAndRelaunch() -> String? {
        UserDefaults.standard.set(buildIdentity, forKey: promptedKey)
        do {
            let script = try makeGrantScript()
            let source = "do shell script \"/bin/sh '\(script.path)'\" with administrator privileges " +
                "with prompt \"Vircam needs your password to turn on camera access.\""
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            try? FileManager.default.removeItem(at: script)
            if let error {
                // -128: the user clicked Cancel.
                if error[NSAppleScript.errorNumber] as? Int == -128 { return nil }
                return "Couldn't turn on camera access: \(error[NSAppleScript.errorMessage] as? String ?? "unknown error")"
            }
            relaunch()
            return nil
        } catch {
            return "Couldn't turn on camera access: \(error.localizedDescription)"
        }
    }

    /// The build's designated requirement, which also identifies it across launches.
    private static var buildIdentity: String {
        (try? output("/usr/bin/codesign", ["-d", "-r-", Bundle.main.bundlePath]))
            .flatMap { text in
                text.split(separator: "\n")
                    .first { $0.contains("designated => ") }
                    .map { String($0.components(separatedBy: "designated => ")[1]) }
            } ?? ""
    }

    private static func makeGrantScript() throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("vircam-grant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let requirement = work.appendingPathComponent("req.txt")
        let compiled = work.appendingPathComponent("req.bin")
        try buildIdentity.write(to: requirement, atomically: true, encoding: .utf8)
        _ = try output("/usr/bin/csreq", ["-r", requirement.path, "-b", compiled.path])
        let hex = try Data(contentsOf: compiled).map { String(format: "%02x", $0) }.joined()

        let bundleID = Bundle.main.bundleIdentifier ?? "dev.vircam.Vircam"
        let database = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let sql = "insert or replace into access (service,client,client_type,auth_value,auth_reason," +
            "auth_version,csreq,policy_id,indirect_object_identifier_type,indirect_object_identifier," +
            "indirect_object_code_identity,flags,last_modified) values ('kTCCServiceCamera','\(bundleID)'," +
            "0,2,3,1,X'\(hex)',NULL,0,'UNUSED',NULL,0,CAST(strftime('%s','now') AS INTEGER));"
        let script = work.appendingPathComponent("grant.sh")
        try """
            set -e
            /usr/bin/sqlite3 '\(database)' "\(sql)"
            /usr/bin/pkill -U \(getuid()) tccd || true
            """.write(to: script, atomically: true, encoding: .utf8)
        return script
    }

    private static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$2\"",
                             "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func output(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Vircam", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: tool).lastPathComponent) failed"])
        }
        return String(decoding: data, as: UTF8.self)
    }
}
