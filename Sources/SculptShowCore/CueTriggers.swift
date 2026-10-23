import Foundation

public struct CueMIDITrigger: Codable, Hashable, Sendable {
    public var channel: Int
    public var status: Int
    public var number: Int
    public init(channel: Int, status: Int, number: Int) { self.channel = channel; self.status = status; self.number = number }
    public var description: String { "\(status == 0x90 ? "Note" : "CC") \(number) · Ch \(channel + 1)" }
}
public struct CueKeyTrigger: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt8 // shift=1, option=2, control=4; Command is reserved to the app
    public var label: String
    public init(keyCode: UInt16, modifiers: UInt8, label: String) { self.keyCode = keyCode; self.modifiers = modifiers; self.label = label }
    public func matches(keyCode: UInt16, modifiers: UInt8) -> Bool { self.keyCode == keyCode && self.modifiers == modifiers }
    public var isValid: Bool {
        keyCode < 128 && modifiers < 8 && !label.isEmpty && label.count <= 40 &&
        (modifiers & 6 != 0 || ![49,48,53,126,125,35,3,46,45,51,117].contains(Int(keyCode)))
    }
}
public struct CueTriggers: Codable, Equatable, Sendable {
    public var midi: CueMIDITrigger?
    public var key: CueKeyTrigger?
    public var oscEnabled = true
    public var oscAlias = "" // full literal address below /sculpt/trigger/
    public init() {}
    public var validationError: String? {
        if let midi, !(0...15).contains(midi.channel) || ![0x90,0xB0].contains(midi.status) || !(0...127).contains(midi.number) { return "Invalid MIDI Note/CC trigger" }
        if let key, !key.isValid { return "This key is reserved for transport/editing. Choose another key or add Option/Control." }
        if !oscAlias.isEmpty {
            let suffix = oscAlias.dropFirst("/sculpt/trigger/".count)
            if !oscAlias.hasPrefix("/sculpt/trigger/") || suffix.isEmpty || suffix.count > 64 ||
                !suffix.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }) {
                return "Use /sculpt/trigger/name with letters, numbers, dash, dot or underscore."
            }
        }
        return nil
    }
}
public enum CueTriggerResolver {
    public static func matching(in show: Show, midi: CueMIDITrigger? = nil, keyCode: UInt16? = nil, modifiers: UInt8 = 0, oscAlias: String? = nil) -> UUID? {
        let matches = show.cueLists.flatMap(\.cues).filter { cue in
            guard cue.enabled else { return false }
            if let midi { return cue.triggers.midi == midi }
            if let keyCode { return cue.triggers.key?.matches(keyCode: keyCode, modifiers: modifiers) == true }
            if let oscAlias { return cue.triggers.oscEnabled && cue.triggers.oscAlias == oscAlias }
            return false
        }
        return matches.count == 1 ? matches[0].id : nil
    }
    public static func conflict(_ triggers: CueTriggers, cueID: UUID, in show: Show) -> String? {
        if let error = triggers.validationError { return error }
        for other in show.cueLists.flatMap(\.cues) where other.id != cueID {
            if let midi = triggers.midi, other.triggers.midi == midi { return "MIDI trigger already assigned to ‘\(other.name)’" }
            if let key = triggers.key, other.triggers.key?.matches(keyCode: key.keyCode, modifiers: key.modifiers) == true { return "Key already assigned to ‘\(other.name)’" }
            if triggers.oscEnabled, other.triggers.oscEnabled, !triggers.oscAlias.isEmpty, other.triggers.oscAlias == triggers.oscAlias { return "OSC alias already assigned to ‘\(other.name)’" }
        }
        return nil
    }
}
