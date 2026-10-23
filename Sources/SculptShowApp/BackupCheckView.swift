import SwiftUI
import AppKit
import CryptoKit
import AVFAudio
import SculptShowCore
import UniformTypeIdentifiers

private enum BackupInspector {
    static func inspect(_ show: Show, channels: Int, uid: String, voiceLimit: Int, deviceRate: Double) throws -> BackupCheckReport {
        var digests: [UUID: String] = [:], cached: [String: String] = [:], media: [String: PreflightAudioInfo] = [:]
        for element in show.cueLists.flatMap(\.cues).flatMap(\.audioElements) {
            try Task.checkCancellation()
            if let digest = cached[element.sourcePath] { digests[element.id] = digest; continue }
            let before = try FileManager.default.attributesOfItem(atPath: element.sourcePath)
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: element.sourcePath))
            var hash = SHA256()
            do {
                while let block = try file.read(upToCount: 1024 * 1024), !block.isEmpty { try Task.checkCancellation(); hash.update(data: block) }
                try file.close()
            } catch { try? file.close(); throw error }
            let after = try FileManager.default.attributesOfItem(atPath: element.sourcePath)
            guard before[.size] as? NSNumber == after[.size] as? NSNumber,
                  before[.modificationDate] as? Date == after[.modificationDate] as? Date else {
                throw SessionAudioPreparation.Failure.invalid("Audio changed during verification. Run the check again.")
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            cached[element.sourcePath] = digest; digests[element.id] = digest
            let audio = try AVAudioFile(forReading: URL(fileURLWithPath: element.sourcePath))
            media[element.sourcePath] = .init(channelCount: Int(audio.processingFormat.channelCount), duration: Double(audio.length) / audio.processingFormat.sampleRate, sampleRate: audio.processingFormat.sampleRate)
        }
        let fingerprint = SHA256.hash(data: try BackupCheckReport.canonicalProject(show, digests: digests)).map { String(format: "%02x", $0) }.joined()
        let preflight = ShowPreflight.check(show, outputChannels: channels, media: media, voiceLimit: voiceLimit, deviceUID: uid)
        var issues = preflight.issues.filter { $0.severity == .blocking }.map(\.message)
        if !digests.isEmpty && channels > 0 && show.monitor.reservedOutputs(deviceUID: uid, channels: channels).count == channels { issues.append("All physical outputs are reserved for Monitor; no program output remains") }
        if abs(deviceRate - Double(show.sampleRate)) > 0.5 { issues.append("Device sample rate does not match the project") }
        return BackupCheckReport(showName: show.name, projectDigest: fingerprint, mediaCount: digests.count, sampleRate: show.sampleRate,
            blockingIssues: issues)
    }
}

struct BackupCheckView: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    @State private var report: BackupCheckReport?
    @State private var inspectedShow: Show?
    @State private var inspectedUID = ""
    @State private var inspectedChannels = 0
    @State private var inspectedRate: Double = 0
    @State private var worker: Task<BackupCheckReport, Error>?
    @State private var status = "Run this check on both Macs, export one report and compare it on the other."
    private var idle: Bool { playback.snapshots.isEmpty && !store.preparingSessionAudio && !store.isLoadingProject && store.pendingAudioImports == 0 }
    private var current: Bool { report != nil && inspectedShow == store.show && inspectedUID == playback.routingDeviceUID &&
        inspectedChannels == playback.routingOutputCount && inspectedRate == playback.deviceSampleRate && idle }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MAIN / BACKUP · COPY CHECK").font(.headline)
            Text("Compares project settings, stable cue IDs and the SHA-256 of every audio file. Local hardware patches are checked on each Mac, not required to be identical.").font(.caption)
            HStack {
                Button(worker == nil ? "Verify this copy" : "Verifying…") { inspect() }.disabled(!idle || worker != nil)
                if worker != nil { Button("Cancel") { worker?.cancel() } }
                Button("Export report…") { exportReport() }.disabled(!current || worker != nil)
                Button("Compare report…") { compare() }.disabled(!current || worker != nil)
            }
            Text(status).textSelection(.enabled).font(.caption)
            if report != nil && !current { Text("Project or playback state changed. Verify again before comparing.").foregroundStyle(.orange).font(.caption) }
            Text("STOP ALL is required for disk verification. Starting playback cancels it. Matching reports check content and basic routing availability; they do not synchronize playback, clocks or physical audio switching. No automatic failover is enabled.").font(.caption).foregroundStyle(.secondary)
        }.padding(20)
        .onChange(of: Set(playback.snapshots.keys)) { if !$0.isEmpty { worker?.cancel() } }
        .onDisappear { worker?.cancel() }
    }
    private func inspect() {
        let show = store.show, channels = playback.routingOutputCount, uid = playback.routingDeviceUID
        let voiceLimit = playback.routingVoiceLimit, deviceRate = playback.deviceSampleRate
        report = nil; inspectedShow = nil; status = "Reading and hashing audio outside the playback engine…"
        let task = Task.detached(priority: .utility) { try BackupInspector.inspect(show, channels: channels, uid: uid, voiceLimit: voiceLimit, deviceRate: deviceRate) }
        worker = task
        Task { @MainActor in
            defer { worker = nil }
            do {
                let result = try await task.value
                guard idle, show == store.show, uid == playback.routingDeviceUID, channels == playback.routingOutputCount, deviceRate == playback.deviceSampleRate else { status = "Project/device changed; verify again."; return }
                report = result; inspectedShow = show
                inspectedUID = uid; inspectedChannels = channels; inspectedRate = deviceRate
                status = "\(result.mediaCount) stems · \(result.sampleRate) Hz\n\(result.blockingIssues.isEmpty ? "Local preflight passed" : result.blockingIssues.joined(separator: "\n"))\nSHA-256: \(result.projectDigest)"
            } catch is CancellationError { status = "Verification cancelled." }
            catch { status = "Verification failed: \(error.localizedDescription)" }
        }
    }
    private func exportReport() {
        guard current, let report else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Sculpt-backup-check.json"
        if panel.runModal() == .OK, let url = panel.url, current {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(report).write(to: url, options: .atomic) }
            catch { status = error.localizedDescription }
        }
    }
    private func compare() {
        guard current, let report else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url, current {
            do {
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                let other = try JSONDecoder().decode(BackupCheckReport.self, from: Data(contentsOf: url))
                let differences = report.differences(from: other)
                status = differences.isEmpty ? "Copies match and both reports have no blocking preflight issues. This is a content check, not a failover test." : differences.joined(separator: "\n")
            } catch { status = "Invalid report: \(error.localizedDescription)" }
        }
    }
}
