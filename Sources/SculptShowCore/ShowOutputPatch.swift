import Foundation

/// Stable logical channel numbers belong to the show; hardware mappings use Core Audio UIDs.
/// No profile means legacy automatic routing, unless a custom patch was explicitly saved.
public struct ShowOutputPatch: Codable, Equatable, Sendable {
    public struct DeviceProfile: Codable, Equatable, Sendable {
        public var deviceUID: String
        public var deviceName: String
        public var automatic: Bool
        public var outputs: [Int?]
        public init(deviceUID: String, deviceName: String, automatic: Bool, outputs: [Int?]) {
            self.deviceUID = deviceUID; self.deviceName = deviceName
            self.automatic = automatic; self.outputs = outputs
        }
    }
    public var names: [String: String] = [:]
    public var profiles: [DeviceProfile] = []
    public init() {}
    public func name(_ channel: Int) -> String {
        let text = names[String(channel)] ?? ""
        return text.isEmpty ? "OUT \(channel)" : text
    }
    public mutating func rename(_ channel: Int, to name: String) {
        guard (1...64).contains(channel) else { return }
        let clean = String(name.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        if clean.isEmpty { names.removeValue(forKey: String(channel)) }
        else { names[String(channel)] = clean }
    }
    public func profile(for uid: String) -> DeviceProfile? { profiles.first { $0.deviceUID == uid } }
    public func isAutomatic(on uid: String) -> Bool {
        profile(for: uid)?.automatic ?? !profiles.contains { !$0.automatic }
    }
    public mutating func setProfile(_ profile: DeviceProfile) {
        profiles.removeAll { $0.deviceUID == profile.deviceUID }
        profiles.append(profile)
    }
    public func validate() throws {
        guard Set(profiles.map(\.deviceUID)).count == profiles.count,
              profiles.allSatisfy({ !$0.deviceUID.isEmpty && $0.outputs.count == 64 &&
                  $0.outputs.allSatisfy { $0 == nil || (1...64).contains($0!) } }),
              names.keys.allSatisfy({ Int($0).map { (1...64).contains($0) } ?? false }) else {
            throw Failure.invalidPatch
        }
    }
    public enum Failure: LocalizedError, Equatable {
        case invalidPatch, missingProfile, invalidRoute, unpatched(Int), unavailable(Int, Int), stereoPair(Int), reserved(Int)
        public var errorDescription: String? {
            switch self {
            case .invalidPatch: return "Invalid output patch data."
            case .missingProfile: return "This show has a custom patch for another interface. Open Output Patch and explicitly configure this interface before GO."
            case .invalidRoute: return "The source does not fit the logical or physical output range."
            case .unpatched(let channel): return "Logical OUT \(channel) is not patched. Open Output Patch before GO."
            case .unavailable(let channel, let physical): return "Logical OUT \(channel) needs physical OUT \(physical), which is unavailable on this interface."
            case .reserved(let output): return "Physical OUT \(output) is reserved for Monitor. Choose a program output."
            case .stereoPair(let channel): return "Logical OUT \(channel)/\(channel + 1) must map to two different physical outputs."
            }
        }
    }
    public func crosspoints(firstOutput: Int, sourceChannels: Int, deviceUID: String,
                            deviceChannels: Int, excluding: Set<Int> = []) throws -> [AudioRoutePlan.Crosspoint] {
        guard (1...64).contains(deviceChannels), (1...2).contains(sourceChannels),
              firstOutput > 0, firstOutput <= 64 else { throw Failure.invalidRoute }
        if isAutomatic(on: deviceUID) {
            let pool = (1...deviceChannels).filter { !excluding.contains($0) }
            if pool.isEmpty && !excluding.isEmpty { return [] } // Monitor-only interface.
            guard pool.count >= sourceChannels else { throw Failure.invalidRoute }
            let first = AudioRoutePlan.wrappedOutput(firstOutput, sourceChannels: sourceChannels, deviceChannels: pool.count)
            let result = (0..<sourceChannels).map { AudioRoutePlan.Crosspoint(sourceChannel: $0, deviceChannel: pool[first - 1 + $0] - 1) }
            return result
        }
        guard firstOutput + sourceChannels - 1 <= 64 else { throw Failure.invalidRoute }
        guard let profile = profile(for: deviceUID) else { throw Failure.missingProfile }
        guard profile.outputs.count == 64 else { throw Failure.invalidPatch }
        let channels = try (0..<sourceChannels).map { offset -> Int in
            let logical = firstOutput + offset
            guard let physical = profile.outputs[logical - 1] else { throw Failure.unpatched(logical) }
            guard !excluding.contains(physical) else { throw Failure.reserved(physical) }
            guard (1...deviceChannels).contains(physical) else { throw Failure.unavailable(logical, physical) }
            return physical
        }
        if sourceChannels == 2 && channels[1] == channels[0] { throw Failure.stereoPair(firstOutput) }
        return channels.enumerated().map { AudioRoutePlan.Crosspoint(sourceChannel: $0.offset, deviceChannel: $0.element - 1) }
    }
}
