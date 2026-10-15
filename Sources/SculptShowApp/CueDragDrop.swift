import Foundation
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

// Distinct native transfer type prevents audio-file drops and ordinary text
// from being misidentified as a cue move.
extension UTType {
    static let sculptShowCue = UTType(exportedAs: "com.gianlucavergalito.sculptshow.cue", conformingTo: .data)
}

struct CueDragPayload: Codable, Transferable {
    let cueID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sculptShowCue)
    }
}
