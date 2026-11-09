import Foundation

/// Strict typed reads from property-list values.
///
/// Values come from `CFPreferences` (NSNumber/NSString/...) or from Swift
/// literals in tests. NSNumber bridges loosely (`true as? Int == 1`, `1 as? Bool == true`),
/// which would let a mistyped profile key silently "work", so booleans and
/// numbers are told apart via the CF type ID.
enum PlistValue {
    static func isBoolean(_ value: Any) -> Bool {
        guard let n = value as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func bool(_ value: Any) -> Bool? {
        guard isBoolean(value), let n = value as? NSNumber else { return nil }
        return n.boolValue
    }

    static func int(_ value: Any) -> Int? {
        guard !isBoolean(value), let n = value as? NSNumber else { return nil }
        let d = n.doubleValue
        guard d.rounded() == d, abs(d) < Double(Int32.max) else { return nil }
        return Int(d)
    }

    static func double(_ value: Any) -> Double? {
        guard !isBoolean(value), let n = value as? NSNumber else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    static func string(_ value: Any) -> String? { value as? String }

    static func array(_ value: Any) -> [Any]? { value as? [Any] }

    static func dictionary(_ value: Any) -> [String: Any]? { value as? [String: Any] }
}
