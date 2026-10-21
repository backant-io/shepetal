import Foundation

/// F99, after Wispr's helper launcher: an exit without the clean-quit marker is a crash and the app is
/// reopened after a backoff (1 s, 2 s, 4 s). A run of 60 s or more starts the count again. The fourth
/// crash in a row, each within a minute of starting, gives up and leaves `gaveUp` for the next launch.
public struct Relaunch: Codable, Equatable {
    public static let resetAfter: TimeInterval = 60
    public static let maxRelaunches = 3
    public static let gaveUpHint = "shepetal kept quitting unexpectedly, so it stopped reopening itself"

    public var crashes = 0  // in a row, each within `resetAfter` of starting
    public var gaveUp = false

    public init(crashes: Int = 0, gaveUp: Bool = false) {
        self.crashes = crashes
        self.gaveUp = gaveUp
    }

    /// The app exited after running `ran` seconds. Returns the delay before reopening it, or nil to stay quit.
    public mutating func exited(clean: Bool, ran: TimeInterval) -> TimeInterval? {
        if clean { crashes = 0; return nil }
        crashes = ran >= Self.resetAfter ? 1 : crashes + 1
        guard crashes <= Self.maxRelaunches else {
            crashes = 0
            gaveUp = true
            return nil
        }
        return pow(2, Double(crashes - 1))
    }
}
