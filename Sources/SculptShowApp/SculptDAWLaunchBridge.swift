import AppKit
import AVFAudio
import Foundation
import SculptShowCore
import UniformTypeIdentifiers

/// Phase 2 of Sculpt Show -> Sculpt DAW. Only the user's explicit EDIT command
/// launches processes. It never changes Show's audio graph or source media.
/// The CLI creates a normal, editable .scraft session; when the CLI isn't
/// installed, Sculpt DAW can import the stems from launch arguments itself.
@MainActor
enum SculptDAWLaunchBridge {
    enum LaunchError: LocalizedError {
        case noApplication, incorrectApplication, invalidAudio(String)
        case invalidCLI, cliRequired, importFailed(String), missingSession
        case unableToCreateWorkspace(String)

        var errorDescription: String? {
            switch self {
            case .noApplication: return "Sculpt DAW was not selected. No changes were made."
            case .incorrectApplication: return "Select Sculpt DAW.app (audio.sculpt.daw), not another application."
            case .invalidAudio(let message): return "Cannot open this cue in DAW: \(message)"
            case .invalidCLI: return "The selected file is not an executable Sculpt DAW CLI. Select Sculpt DAW.app (with its Contents/Helpers/soundcraft-cli) or a valid soundcraft-cli executable."
            case .cliRequired: return "Importing several aligned stems requires soundcraft-cli (included alongside Sculpt DAW.app in the downloaded ZIP). Choose it to open the cue in the DAW."
            case .importFailed(let message): return "Sculpt DAW session preparation failed: \(message)"
            case .missingSession: return "The import command finished but did not create the DAW session."
            case .unableToCreateWorkspace(let message): return "Cannot prepare a DAW workspace: \(message)"
            }
        }
    }

    struct Preparation {
        let dawApplication: URL
        let cli: URL?
        let manifest: SculptBridge.Manifest
        let script: URL
        let session: URL
        let workspace: URL
        let sampleRate: Int
        let channelCounts: [UUID: Int]
    }

    private static let appPreference = "SculptBridge.DAWApplication.v2"
    private static let cliPreference = "SculptBridge.DAWCLI.v2"
    private static let bundleID = "audio.sculpt.daw"

    static func prepare(_ manifest: SculptBridge.Manifest) throws -> Preparation {
        let app = try locateApplication()
        let audioInfo = try checkAudio(manifest)
        var cli = locateCLI(near: app)
        if cli == nil { cli = try chooseCLI(required: true) }
        guard cli != nil else { throw LaunchError.cliRequired }
        let workspace = try createWorkspace(for: manifest)
        let session = workspace.appendingPathComponent("\(SculptBridge.safeFilename(manifest.cueName)).scdaw")
        let script = workspace.appendingPathComponent("import-into-sculpt-daw.txt")
        let json = workspace.appendingPathComponent("sculpt-cue-bridge.json")
        do {
            let commands = try SculptBridge.dawImportScript(manifest,
                sampleRate: audioInfo.rate, destination: session.path,
                channelCounts: audioInfo.channels)
            try SculptBridge.encode(manifest).write(to: json, options: .atomic)
            try Data(commands.utf8).write(to: script, options: .atomic)
        } catch {
            throw LaunchError.unableToCreateWorkspace(error.localizedDescription)
        }
        return Preparation(dawApplication: app, cli: cli, manifest: manifest,
                           script: script, session: session, workspace: workspace,
                           sampleRate: audioInfo.rate, channelCounts: audioInfo.channels)
    }

    static func run(_ preparation: Preparation, report: @escaping @MainActor (Result<String, Error>) -> Void) {
        if let cli = preparation.cli {
            let scriptPath = preparation.script.path
            let session = preparation.session
            let application = preparation.dawApplication
            let workspace = preparation.workspace
            // Never block SwiftUI with a CLI import of long audio files.
            Task {
                do {
                    try await runImport(executable: cli, script: scriptPath, expectedSession: session)
                    openDAW(application, arguments: [session.path]) { result in
                        switch result {
                        case .success:
                            report(.success("Sculpt DAW launched with the prepared session: \(workspace.lastPathComponent). Verify its audio tracks, then edit regions, levels and plugins; save changes in DAW."))
                        case .failure(let error): report(.failure(error))
                        }
                    }
                } catch { report(.failure(error)) }
            }
        } else { report(.failure(LaunchError.cliRequired)) }
    }

    @discardableResult
    static func chooseCLI(required: Bool = false) throws -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Sculpt DAW Command-Line Tool"
        panel.message = "Select Sculpt DAW.app (recommended; CLI is in Contents/Helpers), or select an executable soundcraft-cli."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            if required { throw LaunchError.cliRequired }
            return nil
        }
        // Sculpt DAW Core22 bundles its signed CLI as an application helper.
        // Accept either the whole app or a directly selected CLI executable.
        let tool = url.pathExtension.lowercased() == "app"
            ? url.appendingPathComponent("Contents/Helpers/soundcraft-cli") : url
        guard tool.lastPathComponent == "soundcraft-cli",
              FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw LaunchError.invalidCLI
        }
        UserDefaults.standard.set(tool.path, forKey: cliPreference)
        return tool
    }

    private static func locateApplication() throws -> URL {
        let fm = FileManager.default
        let stored = UserDefaults.standard.string(forKey: appPreference).map(URL.init(fileURLWithPath:))
        let paths: [URL?] = [stored,
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
            URL(fileURLWithPath: "/Applications/Sculpt DAW.app"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Sculpt DAW.app")]
        for candidate in paths.compactMap({ $0 }) {
            if Bundle(url: candidate)?.bundleIdentifier == bundleID {
                UserDefaults.standard.set(candidate.path, forKey: appPreference)
                return candidate
            }
        }
        let panel = NSOpenPanel()
        panel.title = "Locate Sculpt DAW"
        panel.message = "Select the Sculpt DAW.app built from your SculptDAW repository. This location is remembered."
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { throw LaunchError.noApplication }
        guard Bundle(url: url)?.bundleIdentifier == bundleID else { throw LaunchError.incorrectApplication }
        UserDefaults.standard.set(url.path, forKey: appPreference)
        return url
    }

    private static func locateCLI(near app: URL) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidatePaths: [String?] = [
            // Current Sculpt DAW universal package; always prefer its own CLI.
            app.appendingPathComponent("Contents/Helpers/soundcraft-cli").path,
            // Legacy releases can still have a sidecar executable.
            app.deletingLastPathComponent().appendingPathComponent("soundcraft-cli").path,
            UserDefaults.standard.string(forKey: cliPreference),
            home.appendingPathComponent("Downloads/soundcraft-cli").path,
            home.appendingPathComponent("Applications/soundcraft-cli").path,
            "/usr/local/bin/soundcraft-cli", "/opt/homebrew/bin/soundcraft-cli"
        ]
        for path in candidatePaths.compactMap({ $0 }) where fm.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if url.lastPathComponent == "soundcraft-cli" { return url }
        }
        return nil
    }

    private static func checkAudio(_ manifest: SculptBridge.Manifest) throws -> (rate: Int, channels: [UUID: Int]) {
        guard !manifest.stems.isEmpty else { throw LaunchError.invalidAudio("no audio stems") }
        var sampleRate = 48000
        var channels: [UUID: Int] = [:]
        for (index, stem) in manifest.stems.enumerated() {
            let url = URL(fileURLWithPath: stem.sourcePath)
            guard FileManager.default.fileExists(atPath: url.path),
                  let file = try? AVAudioFile(forReading: url),
                  (1...2).contains(Int(file.processingFormat.channelCount)),
                  file.processingFormat.sampleRate >= 8000,
                  file.length > 0 else {
                throw LaunchError.invalidAudio("missing or unreadable mono/stereo file: \(stem.name)")
            }
            if index == 0 { sampleRate = Int(file.processingFormat.sampleRate.rounded()) }
            channels[stem.elementID] = Int(file.processingFormat.channelCount)
        }
        return (sampleRate, channels)
    }

    private static func createWorkspace(for manifest: SculptBridge.Manifest) throws -> URL {
        let fm = FileManager.default
        let folder = (fm.urls(for: .musicDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser)
            .appendingPathComponent("Sculpt Bridge", isDirectory: true)
        let stem = SculptBridge.safeFilename(manifest.cueName)
        let id = manifest.cueID.uuidString.prefix(8)
        // A fresh UUID prevents overwriting an earlier DAW edit of the same cue.
        let unique = UUID().uuidString.prefix(8)
        let workspace = folder.appendingPathComponent("\(stem)-\(id)-\(unique)", isDirectory: true)
        do { try fm.createDirectory(at: workspace, withIntermediateDirectories: true) }
        catch { throw LaunchError.unableToCreateWorkspace(error.localizedDescription) }
        return workspace
    }

    private static func runImport(executable: URL, script: String, expectedSession: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["script", script]
            // A file cannot fill like an undrained pipe when importing many stems.
            let logURL = expectedSession.deletingLastPathComponent().appendingPathComponent("import.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            process.standardError = log
            process.standardOutput = log
            do { try process.run() }
            catch { throw LaunchError.importFailed(error.localizedDescription) }
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let reader = try FileHandle(forReadingFrom: logURL)
                defer { try? reader.close() }
                let raw = try reader.read(upToCount: 4000) ?? Data()
                throw LaunchError.importFailed(String(decoding: raw, as: UTF8.self))
            }
            guard FileManager.default.fileExists(atPath: expectedSession.path) else {
                throw LaunchError.missingSession
            }
        }.value
    }

    private static func openDAW(_ application: URL, arguments: [String],
                                completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = arguments
        // Sending arguments to an existing app instance is not reliable on macOS.
        // A new instance avoids overwriting any DAW session already being edited.
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: application, configuration: config) { _, error in
            Task { @MainActor in
                if let error { completion(.failure(error)) }
                else { completion(.success(())) }
            }
        }
    }
}
