import Foundation

/// A typed guard for returning a duration draft to the cue that owns it.
/// SwiftUI focus changes can arrive after selection changes; never let an old
/// editor mutate the newly selected cue.
public enum CueDurationEditGuard {
    public static func confirmedValue(_ draft: String,
                                      ownerCueID: UUID, ownerListID: UUID,
                                      selectedCueID: UUID?, selectedListID: UUID?) -> Double? {
        guard selectedCueID == ownerCueID && selectedListID == ownerListID else { return nil }
        return CueClock.parse(draft)
    }
}
