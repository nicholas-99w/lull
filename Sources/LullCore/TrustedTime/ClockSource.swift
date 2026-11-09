import Darwin
import Foundation

/// The three raw inputs the trusted-time engine needs. Injected so tests can
/// simulate clock tampering, sleep and reboots.
public protocol ClockSource: Sendable {
    /// System wall clock. Untrusted: any admin can change it.
    var wallNow: Date { get }
    /// Seconds since boot, **including sleep**, monotonic. Can't be changed by the user.
    var continuousSeconds: TimeInterval { get }
    /// Changes on every boot; lets us tell a daemon restart from a reboot.
    var bootSessionUUID: String { get }
}

/// Real clock: `mach_continuous_time()` (keeps counting through sleep, unlike
/// `mach_absolute_time()`) and `kern.bootsessionuuid`.
public struct SystemClockSource: ClockSource {
    private let ticksToSeconds: Double

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        ticksToSeconds = Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    public var wallNow: Date { Date() }

    public var continuousSeconds: TimeInterval { Double(mach_continuous_time()) * ticksToSeconds }

    public var bootSessionUUID: String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
}
