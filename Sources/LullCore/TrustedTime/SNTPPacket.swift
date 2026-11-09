import Foundation

/// Minimal SNTP (RFC 4330 / RFC 5905 client mode) encode/decode. Networking
/// lives in the daemon; this is pure so it can be tested byte by byte.
///
/// The request's transmit timestamp is a random nonce rather than our clock
/// (as chrony does): the server echoes it back as the originate timestamp, so
/// an off-path attacker can't forge a reply without seeing the request, and we
/// never leak the (untrusted) local wall clock. Delay maths uses the continuous
/// clock, so only differences of local times matter.
public enum SNTPPacket {
    public static let size = 48
    /// Seconds from 1900-01-01 (NTP epoch) to 1970-01-01 (unix epoch).
    static let ntpToUnix: TimeInterval = 2_208_988_800

    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case wrongSize(Int)
        case notServerMode(UInt8)
        case unsupportedVersion(UInt8)
        case unsynchronized
        case badStratum(UInt8)
        case originateMismatch
        case zeroTransmit
        case negativeDelay(TimeInterval)
        case roundTripTooLong(TimeInterval)

        public var description: String {
            switch self {
            case .wrongSize(let n): return "wrong packet size \(n)"
            case .notServerMode(let m): return "not a server reply (mode \(m))"
            case .unsupportedVersion(let v): return "unsupported version \(v)"
            case .unsynchronized: return "server is unsynchronized (leap indicator 3)"
            case .badStratum(let s): return "bad stratum \(s)"
            case .originateMismatch: return "originate timestamp doesn't match our request"
            case .zeroTransmit: return "server transmit timestamp is zero"
            case .negativeDelay(let d): return "negative delay \(d)"
            case .roundTripTooLong(let d): return "round trip too long \(d)"
            }
        }
    }

    /// Builds a client request: LI=0, VN=4, Mode=3, transmit timestamp = nonce.
    public static func request(nonce: UInt64) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: size)
        p[0] = (0 << 6) | (4 << 3) | 3
        write64(nonce, into: &p, at: 40)
        return p
    }

    /// Validates a reply and turns it into a sync sample.
    /// - Parameters:
    ///   - sentAt / receivedAt: continuous-clock seconds when the request left and the reply arrived.
    public static func parseResponse(
        _ bytes: [UInt8], nonce: UInt64, sentAt: TimeInterval, receivedAt: TimeInterval,
        server: String, maxRoundTrip: TimeInterval = TrustedClock.maxRoundTrip
    ) -> Result<TimeSyncSample, ValidationError> {
        guard bytes.count >= size else { return .failure(.wrongSize(bytes.count)) }
        let leap = bytes[0] >> 6
        let version = (bytes[0] >> 3) & 0x7
        let mode = bytes[0] & 0x7
        let stratum = bytes[1]
        guard mode == 4 else { return .failure(.notServerMode(mode)) }
        guard (3...4).contains(version) else { return .failure(.unsupportedVersion(version)) }
        guard leap != 3 else { return .failure(.unsynchronized) }
        guard (1...15).contains(stratum) else { return .failure(.badStratum(stratum)) }
        guard read64(bytes, at: 24) == nonce else { return .failure(.originateMismatch) }
        let receiveRaw = read64(bytes, at: 32)
        let transmitRaw = read64(bytes, at: 40)
        guard transmitRaw != 0 else { return .failure(.zeroTransmit) }

        let t2 = unixTime(fromNTP: receiveRaw)
        let t3 = unixTime(fromNTP: transmitRaw)
        // Round-trip delay excluding server processing time (RFC 5905 delta).
        let delay = (receivedAt - sentAt) - (t3 - t2)
        guard delay >= 0 else { return .failure(.negativeDelay(delay)) }
        guard delay <= maxRoundTrip else { return .failure(.roundTripTooLong(delay)) }
        // Assume symmetric paths: the reply took half the delay to reach us.
        return .success(
            TimeSyncSample(
                unixTime: t3 + delay / 2, continuousSeconds: receivedAt,
                roundTrip: delay, server: server))
    }

    /// NTP 64-bit timestamp (32.32 fixed point since 1900) to unix seconds.
    /// Era 0 ends in Feb 2036; values that would land before 2024 are taken to
    /// be era 1 so this keeps working after the rollover.
    static func unixTime(fromNTP raw: UInt64) -> TimeInterval {
        let seconds = TimeInterval(raw >> 32)
        let fraction = TimeInterval(raw & 0xFFFF_FFFF) / 4_294_967_296
        var unix = seconds - ntpToUnix + fraction
        if unix < TrustedClock.saneMinimum { unix += 4_294_967_296 }
        return unix
    }

    static func ntpTimestamp(fromUnix unix: TimeInterval) -> UInt64 {
        var ntp = unix + ntpToUnix
        if ntp >= 4_294_967_296 { ntp -= 4_294_967_296 }
        let seconds = UInt64(ntp)
        let fraction = UInt64((ntp - TimeInterval(seconds)) * 4_294_967_296)
        return (seconds << 32) | fraction
    }

    static func read64(_ b: [UInt8], at i: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { ($0 << 8) | UInt64(b[i + $1]) }
    }

    static func write64(_ v: UInt64, into b: inout [UInt8], at i: Int) {
        for k in 0..<8 { b[i + k] = UInt8((v >> (56 - 8 * UInt64(k))) & 0xFF) }
    }
}

/// Fallback time source: the `Date` header of an HTTPS response (TLS gives us
/// server authenticity that plain SNTP lacks, at one-second resolution).
public enum HTTPDateHeader {
    /// Parses an IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`), the only format
    /// RFC 9110 lets servers send.
    public static func parse(_ value: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    /// The header is truncated to whole seconds and stamped somewhere during
    /// the request, so estimate it as mid-second, mid-flight.
    public static func sample(
        header: String, sentAt: TimeInterval, receivedAt: TimeInterval,
        server: String
    ) -> TimeSyncSample? {
        guard let date = parse(header), receivedAt >= sentAt else { return nil }
        let rtt = receivedAt - sentAt
        // Authenticated: the caller only uses this over HTTPS (TLS-verified).
        return TimeSyncSample(
            unixTime: date.timeIntervalSince1970 + 0.5 + rtt / 2,
            continuousSeconds: receivedAt, roundTrip: rtt, server: server, authenticated: true)
    }
}
