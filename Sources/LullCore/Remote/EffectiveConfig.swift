import Foundation

extension LullConfig {
    /// The config lulld enforces: the profile, with the portal's per-device
    /// settings applied when the profile turns portal management on (lull-portal contract/PORTAL_API.md).
    ///
    /// - The profile's `Enabled = false` always wins; a parent's opt-out can
    ///   only turn downtime *off* for this Mac.
    /// - The profile's `Schedules` are the baseline (IT, per year/device group).
    ///   Per kind (school nights, weekend) a parent can opt out (no windows
    ///   starting on those days), customise (their window replaces the
    ///   profile's) or follow the profile. Before the portal is first reached the profile
    ///   applies as is, so a Mac that never gets online still locks. An
    ///   advanced schedule (windows day by day) replaces all of that instead.
    /// - Everything else, including `DateExceptions` (holidays stay
    ///   school-wide), comes from the profile.
    /// - A parent's "Lock down now" applies even if they opted out of the
    ///   schedules, but never when the profile has `Enabled = false`.
    /// - A parent's "Release now" ends the window in progress at that moment
    ///   (scheduled, lock-down or a holiday `AllDay`), as opting out would.
    /// - A parent's school-holiday choice replaces the usual windows during the
    ///   portal's holiday periods (opted out: none; customised or advanced: theirs).
    public func applying(_ remote: RemoteSettings?) -> LullConfig {
        guard portal != nil, let remote else { return self }
        var c = self
        c.enabled = enabled && remote.enabled
        c.schedules = remote.schedules(over: schedules)
        c.lockNow = enabled ? remote.lockNow : nil
        c.releasedAt = remote.releasedAt
        c.holidaySchedule = remote.holidaySchedule
        return c
    }
}
