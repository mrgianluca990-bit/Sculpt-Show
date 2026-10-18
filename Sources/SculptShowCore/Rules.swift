import Foundation

/// Interaction Rules are independently authored, not a proprietary Ovation file format.
/// All IDs are stable so references survive cue reordering and show saving.
public enum RuleEvent: String, CaseIterable, Codable, Sendable {
    case starting = "Starting"
    case ending = "Ending"
    case stopping = "Stopping"
}

public enum RuleAction: String, CaseIterable, Codable, Sendable {
    case fire = "Fire"
    case stop = "Stop"
    case pause = "Pause"
    case fade = "Fade Out"
    case select = "Select"
    case dim = "Dim"
    case undim = "Restore Gain"
}

public enum RuleTarget: String, CaseIterable, Codable, Sendable {
    case nextCue = "Next Cue"
    case previousCue = "Previous Cue"
    case itself = "Itself"
    case specificCue = "Specific Cue"
    case cueList = "Cue List"
    case allCues = "All Cues" // Legacy decoding only.
    public static let allCases: [RuleTarget] = [.nextCue, .previousCue, .itself, .specificCue, .cueList]
}

public enum RuleCueState: String, CaseIterable, Codable, Sendable {
    case playing = "Playing"
    case paused = "Paused"
    case waiting = "Waiting"
    case stopped = "Stopped"
}

public struct InteractionRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var event: RuleEvent
    public var action: RuleAction
    public var target: RuleTarget
    /// Cue UUID for specificCue, list UUID for cueList; otherwise unused.
    public var targetID: UUID?
    public var delaySeconds: Double
    public var excludeSource: Bool?
    public var conditionCueID: UUID?
    public var conditionState: RuleCueState
    public var dimDecibels: Double
    public var fadeSeconds: Double?
    public var fireFadeInSeconds: Double?
    /// Optional destination Marker when Action=Fire. UUID stays stable when markers are moved.
    /// Old projects decode with nil and keep their original behavior.
    public var fireAtMarkerID: UUID?

    public init(id: UUID = UUID(), enabled: Bool = true,
                event: RuleEvent = .ending, action: RuleAction = .fire,
                target: RuleTarget = .nextCue, targetID: UUID? = nil,
                delaySeconds: Double = 0, conditionCueID: UUID? = nil,
                conditionState: RuleCueState = .playing, dimDecibels: Double = -12,
                fadeSeconds: Double? = nil, fireFadeInSeconds: Double? = nil, fireAtMarkerID: UUID? = nil, excludeSource: Bool = false) {
        self.excludeSource = excludeSource
        self.id = id
        self.enabled = enabled
        self.event = event
        self.action = action
        self.target = target
        self.targetID = targetID
        self.delaySeconds = max(0, min(600, delaySeconds))
        self.conditionCueID = conditionCueID
        self.conditionState = conditionState
        self.dimDecibels = min(0, max(-80, dimDecibels))
        self.fadeSeconds = fadeSeconds.map { max(0, min(600, $0)) }
        self.fireFadeInSeconds = fireFadeInSeconds.map { max(0, min(600, $0)) }
        self.fireAtMarkerID = fireAtMarkerID
    }
}

public enum RuleScope: Identifiable, Equatable, Sendable {
    case show
    case cueList(UUID)
    case cue(UUID, in: UUID)
    case marker(UUID, in: UUID)

    public var id: String {
        switch self {
        case .show: return "show"
        case .cueList(let id): return "list-\(id.uuidString)"
        case .cue(let id, _): return "cue-\(id.uuidString)"
        case .marker(let id, _): return "marker-\(id.uuidString)"
        }
    }
}

/// A match of an active event to an enabled rule; execution is performed by ShowStore.
public struct RuleCommand: Equatable, Sendable {
    public var rule: InteractionRule
    public var sourceCueID: UUID
    public var targets: [UUID]
}

/// Pure planner. The app supplies its *current* playback state when an event occurs.
public enum RulePlanner {
    public static func effectiveRules(for sourceID: UUID, in show: Show) -> [InteractionRule] {
        guard let list = show.cueLists.first(where: { $0.cues.contains(where: { $0.id == sourceID }) }),
              let cue = list.cues.first(where: { $0.id == sourceID }) else { return [] }
        if cue.ignoreParentRules { return cue.rules }
        // Parent rules are inherited additions, never replacements for local
        // rules. Each rule independently checks its event and condition.
        return (list.ignoreParentRules ? [] : show.rules) + list.rules + cue.rules
    }

    public static func commands(for event: RuleEvent, source sourceID: UUID,
                                in show: Show, states: [UUID: RuleCueState]) -> [RuleCommand] {
        guard let list = show.cueLists.first(where: { $0.cues.contains(where: { $0.id == sourceID }) }) else { return [] }
        return effectiveRules(for: sourceID, in: show).compactMap { rule in
            guard rule.enabled, rule.event == event else { return nil }
            if let conditionID = rule.conditionCueID {
                // A nonexistent condition cue must NOT accidentally satisfy "Stopped".
                guard show.cue(conditionID) != nil,
                      (states[conditionID] ?? .stopped) == rule.conditionState else { return nil }
            }
            let ids = resolve(rule.target, id: rule.targetID, source: sourceID, list: list, show: show, action: rule.action)
            let targets = rule.excludeSource == true ? ids.filter { $0 != sourceID } : ids
            guard !targets.isEmpty else { return nil }
            return RuleCommand(rule: rule, sourceCueID: sourceID, targets: targets)
        }
    }

    /// Marker-local rules fire only when this exact marker is crossed. Parent
    /// starting/ending/stopping rules remain separate and are not replayed here.
    public static func markerCommands(markerID: UUID, source sourceID: UUID,
                                      in show: Show, states: [UUID: RuleCueState]) -> [RuleCommand] {
        guard let list = show.cueLists.first(where: { $0.cues.contains(where: { $0.id == sourceID }) }),
              let cue = list.cues.first(where: { $0.id == sourceID }),
              let marker = cue.markers.first(where: { $0.id == markerID }) else { return [] }
        return marker.rules.compactMap { rule in
            guard rule.enabled else { return nil }
            if let checked = rule.conditionCueID {
                guard show.cue(checked) != nil,
                      (states[checked] ?? .stopped) == rule.conditionState else { return nil }
            }
            let ids = resolve(rule.target, id: rule.targetID, source: sourceID,
                              list: list, show: show, action: rule.action)
            let targets = rule.excludeSource == true ? ids.filter { $0 != sourceID } : ids
            return targets.isEmpty ? nil : RuleCommand(rule: rule, sourceCueID: sourceID, targets: targets)
        }
    }

    private static func resolve(_ target: RuleTarget, id: UUID?, source: UUID,
                                list: CueList, show: Show, action: RuleAction) -> [UUID] {
        switch target {
        case .itself: return [source]
        case .nextCue: return show.followingCue(after: source).map { [$0.id] } ?? []
        case .previousCue:
            guard let position = list.cues.firstIndex(where: { $0.id == source }) else { return [] }
            return list.cues[..<position].last(where: { $0.enabled }).map { [$0.id] } ?? []
        case .specificCue:
            guard let id, show.cue(id) != nil else { return [] }
            return [id]
        case .cueList:
            guard let id, let other = show.cueLists.first(where: { $0.id == id }) else { return [] }
            if action == .fire || action == .select {
                return other.cues.first(where: { $0.enabled }).map { [$0.id] } ?? []
            }
            return other.cues.map(\.id)
        case .allCues:
            return show.cueLists.flatMap { $0.cues }.map(\.id)
        }
    }
}
