import Foundation
import IOKit
import LullCore

/// The device token from registration, bound to the portal that issued it, so
/// changing `Portal.URL` makes lulld register with the new portal rather than
/// send this token somewhere else.
public struct PortalCredentials: Codable, Sendable, Equatable {
    public var portalURL: String
    public var deviceId: String
    /// Bearer secret. Never logged; written only to the root-only portal.json.
    public var deviceToken: String

    public init(portalURL: String, deviceId: String, deviceToken: String) {
        self.portalURL = portalURL
        self.deviceId = deviceId
        self.deviceToken = deviceToken
    }
}

/// `/var/db/lull/portal-enroll.json` (`{"EnrolmentSecret": "..."}`, written by
/// a Jamf policy) and `/var/db/lull/portal.json` (credentials). Both must be
/// root-owned with no group/other access, like override.json: the enrolment
/// secret lets a Mac register, so it must not be readable by students, and a
/// user-writable token file would let a student point lulld at their own
/// device record. Error messages never include file contents.
public enum PortalCredentialFile {
    public static let secretKey = "EnrolmentSecret"

    public enum LoadError: Error, CustomStringConvertible, Equatable {
        case file(SecureFile.Failure)
        case malformed(String)

        public var description: String {
            switch self {
            case .file(let f): return f.description
            case .malformed(let what): return "expected \(what)"
            }
        }
    }

    /// nil when the file doesn't exist (not enrolled by Jamf yet).
    public static func loadEnrolmentSecret(path: String, owner: uid_t) -> Result<String?, LoadError> {
        switch SecureFile.readTrusted(path, owner: owner) {
        case .failure(let f): return .failure(.file(f))
        case .success(nil): return .success(nil)
        case .success(let data?):
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let s = (obj[secretKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
            else { return .failure(.malformed("a JSON object with a non-empty \(secretKey)")) }
            return .success(s)
        }
    }

    public static func loadCredentials(path: String, owner: uid_t) -> Result<PortalCredentials?, LoadError> {
        switch SecureFile.readTrusted(path, owner: owner) {
        case .failure(let f): return .failure(.file(f))
        case .success(nil): return .success(nil)
        case .success(let data?):
            guard let c = try? JSONDecoder().decode(PortalCredentials.self, from: data) else {
                return .failure(.malformed("portal credentials JSON"))
            }
            return .success(c)
        }
    }

    public static func saveCredentials(_ c: PortalCredentials, path: String) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        try SecureFile.writeAtomically(try e.encode(c), to: path, mode: 0o600)
    }

    public static func deleteCredentials(path: String) {
        unlink(path)
    }

    /// After IT de-registers the Mac, so it can't quietly register again: a
    /// fresh enrolment (the Jamf policy) is needed to manage it remotely again.
    public static func deleteEnrolmentSecret(path: String) {
        unlink(path)
    }
}

/// The Mac's serial number and hardware UUID, sent once when registering.
public protocol DeviceIdentifying {
    func identity() -> (serialNumber: String, hardwareUUID: String)?
}

/// Reads IOPlatformExpertDevice (the same values as System Information).
/// VERIFY on the test Mac (Docs/TESTING.md H1): that the root daemon can read
/// the serial and UUID, also on a VM.
public struct SystemDeviceIdentity: DeviceIdentifying {
    public init() {}

    public func identity() -> (serialNumber: String, hardwareUUID: String)? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> String? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        }
        guard let serial = property(kIOPlatformSerialNumberKey), !serial.isEmpty,
            let uuid = property(kIOPlatformUUIDKey), !uuid.isEmpty
        else { return nil }
        return (serial, uuid)
    }
}
