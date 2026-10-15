import SwiftUI

/// Operator configuration invoked from File → Audio/MIDI Setup.
/// The mixer is independent and accessible from the global transport.
struct AudioMIDISetupView: View {
    @EnvironmentObject private var playback: PlaybackEngine
    @EnvironmentObject private var midi: MIDIControl
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AUDIO / MIDI SETUP")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            Picker("Section", selection: $tab) {
                Text("Core Audio").tag(0)
                Text("MIDI Control").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            if tab == 0 {
                OutputRoutingView().environmentObject(playback)
            } else {
                MIDIControlSettings().environmentObject(midi)
            }
        }
        .frame(width: 690)
    }
}
