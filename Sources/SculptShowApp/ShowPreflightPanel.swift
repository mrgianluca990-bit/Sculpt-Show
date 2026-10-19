import SwiftUI
import AppKit
import AVFAudio
import UniformTypeIdentifiers
import SculptShowCore

/// Non-destructive, read-only show audit. Relinking is an explicit user action;
/// opening this panel never touches playback or hardware routing.
struct ShowPreflightPanel: View {
    @EnvironmentObject private var store: ShowStore
    @EnvironmentObject private var playback: PlaybackEngine
    @Environment(\.dismiss) private var dismiss
    @State private var result: ShowPreflightReport?
    @State private var relinkedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("SHOW PREFLIGHT", systemImage: "checkmark.shield")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                Spacer()
                Button("Rescan") { scan() }
                Button("Export JSON…") { exportJSON() }
                    .disabled(result == nil)
                Button("Relink Folder…") { chooseFolder() }
                Button("Close") { dismiss() }
            }
            if let result {
                HStack(spacing: 18) {
                    status("CUES", "\(result.checkedCues)")
                    status("MEDIA", "\(result.checkedAudioFiles)")
                    status("BLOCKING", "\(result.blockingCount)", color: result.blockingCount > 0 ? .red : .green)
                    status("WARNINGS", "\(result.warningCount)", color: result.warningCount > 0 ? .orange : .green)
                }
                if result.ready && result.warningCount == 0 {
                    Label("No issues detected in the checked media and routing assignments.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
                if let relinkedMessage { Text(relinkedMessage).foregroundColor(.secondary) }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(result.issues.enumerated()), id: \.offset) { entry in
                            let issue = entry.element
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: issue.severity == .blocking ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(issue.severity == .blocking ? .red : .orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(issue.cueName).font(.system(size: 12, weight: .bold))
                                    Text(issue.message).font(.system(size: 11)).foregroundStyle(.secondary)
                                    if let path = issue.mediaPath {
                                        Text(path).font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.tertiary).textSelection(.enabled)
                                    }
                                }
                                Spacer(minLength: 3)
                                if issue.code == "media-missing", let path = issue.mediaPath,
                                   let cueID = issue.cueID {
                                    Button("Locate…") { locate(path: path, cueID: cueID) }
                                        .controlSize(.small)
                                }
                            }
                            .padding(9)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            } else { ProgressView("Checking show media...") }
            Divider()
            Text("Preflight checks media decode, output assignments, voice limits and marker reachability. " +
                 "It does not measure device latency, verify the external speaker wiring or guarantee seamless operation during an actual show. " +
                 "Relinking a file does not interrupt an active cue; the replacement is used on its next playback.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 790, height: 590)
        .onAppear(perform: scan)
    }

    private func status(_ name: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundColor(color)
        }
    }

    private func scan() {
        var metadata: [String: PreflightAudioInfo] = [:]
        let paths = Set(store.show.cueLists.flatMap(\.cues).flatMap(\.audioElements).map(\.sourcePath))
        for path in paths {
            guard let audio = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { continue }
            let rate = audio.processingFormat.sampleRate
            let duration = rate > 0 ? Double(audio.length) / rate : 0
            metadata[path] = PreflightAudioInfo(channelCount: Int(audio.processingFormat.channelCount),
                                                duration: duration, sampleRate: rate)
        }
        result = ShowPreflight.check(store.show,
                                      outputChannels: playback.routingEnabled ? playback.routingOutputCount : 0,
                                      media: metadata, deviceUID: playback.routingDeviceUID)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Locate Missing Show Media"
        panel.message = "Only unambiguous, exactly matching filenames will be relinked."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let count = store.relinkMissingMedia(in: url)
        relinkedMessage = count == 0 ? "No unambiguous missing media found." : "Relinked \(count) missing media references."
        scan()
    }

    private func exportJSON() {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.title = "Export Show Preflight Report"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Sculpt-Show-Preflight.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let payload: [String: Any] = [
            "application": "Sculpt Show",
            "show": store.show.name,
            "scannedAt": ISO8601DateFormatter().string(from: Date()),
            "deviceOutputs": playback.routingOutputCount,
            "cueCount": result.checkedCues,
            "audioFiles": result.checkedAudioFiles,
            "blockingCount": result.blockingCount,
            "warningCount": result.warningCount,
            "ready": result.ready,
            "issues": result.issues.map { issue -> [String: Any] in
                ["severity": issue.severity == .blocking ? "blocking" : "warning",
                 "code": issue.code,
                 "cue": issue.cueName,
                 "cueID": issue.cueID?.uuidString ?? "",
                 "mediaPath": issue.mediaPath ?? "",
                 "message": issue.message]
            }
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            relinkedMessage = "Preflight report exported."
        } catch { relinkedMessage = "Cannot export report: \(error.localizedDescription)" }
    }

    private func locate(path: String, cueID: UUID) {
        for list in store.show.cueLists {
            guard let cue = list.cues.first(where: { $0.id == cueID }),
                  let element = cue.audioElements.first(where: { $0.sourcePath == path }) else { continue }
            store.chooseRelink(for: element.id, cueID: cueID, listID: list.id)
            scan()
            return
        }
    }
}
