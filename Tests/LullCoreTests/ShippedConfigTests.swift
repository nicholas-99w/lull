import XCTest

@testable import LullCore

/// The files in Config/ (example profile, Jamf schema, Service Management
/// profile) must stay consistent with the settings the parser implements.
final class ShippedConfigTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func url(_ path: String) -> URL { repo.appendingPathComponent(path) }

    /// Every key the parser understands, as dotted paths.
    static var allParserKeys: Set<String> {
        var keys = ConfigParser.generalKeys
        keys.formUnion(ConfigParser.appearanceKeys.map { "Appearance.\($0)" })
        keys.formUnion(ConfigParser.textKeys.map { "Texts.\($0.0)" })
        keys.formUnion(ConfigParser.portalKeys.map { "Portal.\($0)" })
        keys.formUnion(["Schedules[].Name", "Schedules[].Days", "Schedules[].Start", "Schedules[].End", "Schedules[].WarningMinutes"])
        keys.formUnion(["DateExceptions[].StartDate", "DateExceptions[].EndDate", "DateExceptions[].Mode", "DateExceptions[].Note"])
        return keys
    }

    static func keyPaths(_ dict: [String: Any], prefix: String = "") -> Set<String> {
        var out = Set<String>()
        for (k, v) in dict {
            let path = prefix.isEmpty ? k : "\(prefix).\(k)"
            out.insert(path)
            if let d = v as? [String: Any] { out.formUnion(keyPaths(d, prefix: path)) }
            if let a = v as? [[String: Any]] { for d in a { out.formUnion(keyPaths(d, prefix: path + "[]")) } }
        }
        return out
    }

    func exampleSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.url("Config/au.com.nickit.lull.mobileconfig"))
        let profile = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(profile["PayloadType"] as? String, "Configuration")
        XCTAssertEqual(profile["PayloadScope"] as? String, "System", "device-level scope")
        let payload = try XCTUnwrap((profile["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.ManagedClient.preferences")
        let domain = try XCTUnwrap((payload["PayloadContent"] as? [String: Any])?[LullConstants.preferenceDomain] as? [String: Any])
        let forced = try XCTUnwrap((domain["Forced"] as? [[String: Any]])?.first)
        return try XCTUnwrap(forced["mcx_preference_settings"] as? [String: Any])
    }

    /// The version lulld and lullctl report is a constant (they have no
    /// Info.plist), so it must be bumped together with the app's version.
    func testVersionConstantMatchesProjectVersion() throws {
        let yml = try String(contentsOf: Self.url("project.yml"), encoding: .utf8)
        let line = try XCTUnwrap(yml.split(separator: "\n").first { $0.contains("MARKETING_VERSION:") })
        let value = line.split(separator: ":", maxSplits: 1)[1]
            .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        XCTAssertEqual(LullConstants.version, value, "update LullConstants.version to match project.yml")
    }

    func testExampleProfileParsesCleanly() throws {
        let branding = LullConstants.brandingDirectory
        let images = ImagePathValidator(
            files: FakeFiles(sizes: ["banner.png", "logo.png", "background.jpg"].reduce(into: [:]) { $0["\(branding)/\($1)"] = 1000 }))
        let result = ConfigParser(images: images).parse(try exampleSettings())
        XCTAssertEqual(result.issues, [], "the shipped example must have no errors or warnings")
        let c = try XCTUnwrap(result.config)
        XCTAssertEqual(c.schedules.map(\.name), ["School night", "Weekend"])
        XCTAssertEqual(c.schedules[0].days, [.mon, .tue, .wed, .thu, .fri])
        XCTAssertEqual(c.schedules[0].start, TimeOfDay(string: "21:30"))
        XCTAssertNotNil(c.overridePasswordHash)
        XCTAssertEqual(c.dateExceptions.count, 2)
    }

    func testExampleProfileUsesEveryKey() throws {
        let used = Self.keyPaths(try exampleSettings())
        XCTAssertEqual(Self.allParserKeys.subtracting(used).sorted(), [], "keys missing from the example profile")
        XCTAssertEqual(used.subtracting(Self.allParserKeys).sorted(), [], "keys in the example the parser doesn't know")
    }

    /// The Team ID login items profile, rendered the way make-release.sh does it.
    static let exampleTeamID = "ABCDE12345"
    static func profile(_ name: String) throws -> [String: Any] {
        var data = try Data(contentsOf: Self.url("Config/\(name)"))
        if name.hasSuffix(".template") {
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            data = Data(text.replacingOccurrences(of: "@TEAM_ID@", with: exampleTeamID).utf8)
        }
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func serviceManagementRules(_ name: String) throws -> [[String: String]] {
        let p = try Self.profile(name)
        let payload = try XCTUnwrap((p["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.servicemanagement")
        return try XCTUnwrap(payload["Rules"] as? [[String: String]])
    }

    func testProfilesHaveUniqueUUIDs() throws {
        var seen = Set<String>()
        var identifiers = Set<String>()
        for name in [
            "au.com.nickit.lull.mobileconfig", "servicemanagement.mobileconfig", "servicemanagement-teamid.mobileconfig.template",
        ] {
            let p = try Self.profile(name)
            // Distinct identifiers too, so both login items profiles can be installed during a rollout.
            XCTAssertTrue(identifiers.insert(try XCTUnwrap(p["PayloadIdentifier"] as? String)).inserted, name)
            let uuids =
                [p["PayloadUUID"] as? String] + ((p["PayloadContent"] as? [[String: Any]]) ?? []).map { $0["PayloadUUID"] as? String }
            for id in uuids {
                let id = try XCTUnwrap(id)
                XCTAssertNotNil(UUID(uuidString: id), "\(name): \(id)")
                XCTAssertTrue(seen.insert(id).inserted, "duplicate PayloadUUID \(id)")
            }
        }
    }

    func testServiceManagementRulesCoverBothLabels() throws {
        let rules = try serviceManagementRules("servicemanagement.mobileconfig")
        let labels = Set(rules.filter { $0["RuleType"] == "Label" }.compactMap { $0["RuleValue"] })
        XCTAssertEqual(labels, [LullConstants.daemonLabel, LullConstants.agentLabel])
        let allowed: Set = ["BundleIdentifier", "BundleIdentifierPrefix", "Label", "LabelPrefix", "TeamIdentifier"]
        for r in rules { XCTAssertTrue(allowed.contains(r["RuleType"] ?? ""), "\(r)") }
        // Must keep matching ad-hoc builds, which have no Team ID.
        for r in rules { XCTAssertNil(r["TeamIdentifier"], "\(r)") }
    }

    func testTeamIDServiceManagementProfileMatchesTheDefaultPlusTeam() throws {
        let plain = try serviceManagementRules("servicemanagement.mobileconfig")
        let team = try serviceManagementRules("servicemanagement-teamid.mobileconfig.template")
        for r in team { XCTAssertEqual(r["TeamIdentifier"], Self.exampleTeamID, "\(r)") }
        let key = { (r: [String: String]) in "\(r["RuleType"] ?? "") \(r["RuleValue"] ?? "")" }
        XCTAssertEqual(team.map(key), plain.map(key))
    }

    func testLaunchdTemplatesUseTheRightLabels() throws {
        for (name, label) in [("LaunchDaemon", LullConstants.daemonLabel), ("LaunchAgent", LullConstants.agentLabel)] {
            let text = try String(contentsOf: Self.url("Resources/\(name).plist.template"), encoding: .utf8)
                .replacingOccurrences(of: "@DAEMON_LABEL@", with: LullConstants.daemonLabel)
                .replacingOccurrences(of: "@AGENT_LABEL@", with: LullConstants.agentLabel)
                .replacingOccurrences(of: "@INSTALL_ROOT@", with: LullConstants.installRoot)
            let p = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any])
            XCTAssertEqual(p["Label"] as? String, label)
            XCTAssertEqual(p["KeepAlive"] as? Bool, true)
            XCTAssertEqual(p["RunAtLoad"] as? Bool, true)
        }
    }

    // MARK: Jamf custom schema

    func schema() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.url("Config/jamf-custom-schema.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Dotted key paths declared by the schema (arrays of objects as `Key[]`).
    static func schemaKeys(_ properties: [String: Any], prefix: String = "") -> Set<String> {
        var out = Set<String>()
        for (k, v) in properties {
            let path = prefix.isEmpty ? k : "\(prefix).\(k)"
            out.insert(path)
            guard let p = v as? [String: Any] else { continue }
            if let nested = p["properties"] as? [String: Any] { out.formUnion(schemaKeys(nested, prefix: path)) }
            if let items = p["items"] as? [String: Any], let nested = items["properties"] as? [String: Any] {
                out.formUnion(schemaKeys(nested, prefix: path + "[]"))
            }
        }
        return out
    }

    func testSchemaDeclaresExactlyTheParserKeys() throws {
        let props = try XCTUnwrap(try schema()["properties"] as? [String: Any])
        let declared = Self.schemaKeys(props)
        XCTAssertEqual(Self.allParserKeys.subtracting(declared).sorted(), [], "keys missing from the Jamf schema")
        XCTAssertEqual(declared.subtracting(Self.allParserKeys).sorted(), [], "schema keys the parser doesn't know")
    }

    /// Jamf writes `default` for fields an admin never touches, so every schema
    /// default must equal Lull's own default (i.e. change nothing).
    func testSchemaDefaultsChangeNothing() throws {
        let props = try XCTUnwrap(try schema()["properties"] as? [String: Any])
        func defaults(_ props: [String: Any]) -> [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in props {
                guard let p = v as? [String: Any] else { continue }
                if let d = p["default"] { out[k] = d }
                if let nested = p["properties"] as? [String: Any] { out[k] = defaults(nested) }
            }
            return out
        }
        var written = defaults(props)
        let minimal: [String: Any] = [
            "Timezone": "Australia/Sydney",
            "Schedules": [["Days": ["Mon"], "Start": "21:30", "End": "06:30"]],
        ]
        written.merge(minimal) { $1 }
        XCTAssertGreaterThan(written.count, 15, "schema should carry defaults")
        let withDefaults = ConfigParser().parse(written)
        XCTAssertEqual(withDefaults.issues, [])
        XCTAssertEqual(withDefaults.config, ConfigParser().parse(minimal).config)
    }

    func testSchemaEnumsMatchTheParser() throws {
        let props = try XCTUnwrap(try schema()["properties"] as? [String: Any])
        func enumValues(_ key: String, in p: [String: Any] = [:]) -> Set<String> {
            let dict = p.isEmpty ? props : p
            return Set(((dict[key] as? [String: Any])?["enum"] as? [String]) ?? [])
        }
        XCTAssertEqual(enumValues("OfflineBootPolicy"), Set(OfflineBootPolicy.allCases.map(\.rawValue)))
        XCTAssertEqual(enumValues("FallbackActionIfAgentMissing"), Set(FallbackAction.allCases.map(\.rawValue)))
        let appearance = try XCTUnwrap((props["Appearance"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertEqual(enumValues("BackgroundStyle", in: appearance), Set(BackgroundStyle.allCases.map(\.rawValue)))
        XCTAssertEqual(enumValues("WarningCardPosition", in: appearance), Set(WarningCardPosition.allCases.map(\.rawValue)))
        XCTAssertEqual(enumValues("BannerContentMode", in: appearance), Set(BannerContentMode.allCases.map(\.rawValue)))
        // Every enum has matching titles (Jamf shows them in the pop-up).
        func checkTitles(_ props: [String: Any]) {
            for (k, v) in props {
                guard let p = v as? [String: Any] else { continue }
                if let e = p["enum"] as? [String] {
                    XCTAssertEqual(((p["options"] as? [String: Any])?["enum_titles"] as? [String])?.count, e.count, k)
                }
                if let nested = p["properties"] as? [String: Any] { checkTitles(nested) }
                if let items = p["items"] as? [String: Any] {
                    if let nested = items["properties"] as? [String: Any] { checkTitles(nested) }
                }
            }
        }
        checkTitles(props)
    }
}
