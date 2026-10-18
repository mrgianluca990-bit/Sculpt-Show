import Foundation

/// A shuffle bag: each enabled cue plays once per round. Saved cue order is untouched.
public struct PlaylistOrder: Sendable {
    private var played: Set<UUID> = []
    public init() {}
    public mutating func record(_ cueID: UUID) { played.insert(cueID) }
    public mutating func next(in list: CueList, after current: UUID?) -> UUID? {
        let enabled = list.cues.filter(\.enabled).map(\.id)
        guard !enabled.isEmpty else { return nil }
        if let current { record(current) }
        if list.randomOrder {
            var candidates = enabled.filter { !played.contains($0) }
            if candidates.isEmpty {
                guard list.repeatAll else { return nil }
                played.removeAll()
                candidates = enabled.count > 1 ? enabled.filter { $0 != current } : enabled
            }
            guard let chosen = candidates.randomElement() else { return nil }
            record(chosen)
            return chosen
        }
        if let current, let index = enabled.firstIndex(of: current) {
            if index + 1 < enabled.count { return enabled[index + 1] }
            return list.repeatAll ? enabled.first : nil
        }
        return enabled.first
    }
}
