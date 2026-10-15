import Foundation

/// Navigation never creates multiple selected cue states and never wraps inside a list.
public enum CueNavigator {
    public static func neighbor(in show: Show, listID: UUID,
                                selectedCueID: UUID?, direction: Int) -> UUID? {
        guard let list = show.cueLists.first(where: { $0.id == listID }), direction != 0 else { return nil }
        let available = list.cues.filter(\.enabled)
        guard !available.isEmpty else { return nil }
        guard let selectedCueID, let position = available.firstIndex(where: { $0.id == selectedCueID }) else {
            return direction > 0 ? available.first?.id : available.last?.id
        }
        let next = position + (direction > 0 ? 1 : -1)
        return available.indices.contains(next) ? available[next].id : nil
    }

    /// Cycles to the next list; its cue selection is set by the UI to its first enabled cue.
    public static func nextList(in show: Show, currentListID: UUID?) -> UUID? {
        guard !show.cueLists.isEmpty else { return nil }
        guard let currentListID, let index = show.cueLists.firstIndex(where: { $0.id == currentListID }) else {
            return show.cueLists.first?.id
        }
        return show.cueLists[(index + 1) % show.cueLists.count].id
    }
}
