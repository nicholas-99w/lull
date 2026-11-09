import Foundation

/// User-facing strings that aren't configurable through `Texts` (no
/// hard-coded user-facing strings outside defaults in LullCore). Kept in
/// one place so they can be localised later.
public enum UIStrings {
    public static func availableAgainIn(_ duration: String) -> String { "Available again in \(duration)" }
    public static func locksIn(_ duration: String) -> String { "Locks in \(duration)" }

    public static let overrideTitle = "Administrator override"
    public static let overrideMessage = "Enter the override passphrase to unlock this Mac for a limited time."
    public static let passphrasePlaceholder = "Passphrase"
    public static let cancel = "Cancel"
    public static let unlock = "Unlock"
    public static let checking = "Checking…"

    public static func overrideRejected(attemptsRemaining: Int) -> String {
        attemptsRemaining == 1
            ? "Incorrect passphrase. 1 attempt remaining."
            : "Incorrect passphrase. \(attemptsRemaining) attempts remaining."
    }
    public static func overrideLockedOut(until time: String) -> String { "Too many attempts. Try again at \(time)." }
    public static func overrideGranted(until time: String) -> String { "Unlocked until \(time)." }
    public static let overrideUnavailable = "Override isn't available right now."

    // Shut Down is a forced shutdown (by design), so the confirmation
    // always warns about lost work and offers Sleep as the safe alternative.
    public static let shutdownConfirmTitle = "Shut down this Mac?"
    public static let shutdownConfirmMessage =
        "Shutting down closes every app immediately. Anything you haven't saved will be lost."
    public static let shutdownSleepAlternative =
        "To keep your apps and documents open, choose Sleep or close the lid instead. Everything will be where you left it when downtime ends."
    public static let sleep = "Sleep"

    // Accessibility
    public static let timeRemaining = "Time remaining"
    public static let downtimeProgress = "Downtime progress"
    public static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded())) percent" }
}
