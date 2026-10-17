/// Chooses a recovery target after focus disappears, not an initial playback source.
enum StreamPickerFocusRecovery {
    static func target(
        lastFocusedID: String?, restoredSourceID: String?,
        streamIDs: [String], filterIDs: Set<String>, fallbackFilterID: String
    ) -> String {
        if let lastFocusedID,
           filterIDs.contains(lastFocusedID) || streamIDs.contains(lastFocusedID) {
            return lastFocusedID
        }
        if let restoredSourceID, streamIDs.contains(restoredSourceID) {
            return restoredSourceID
        }
        return streamIDs.first ?? fallbackFilterID
    }
}
