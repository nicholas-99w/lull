import XCTest

@testable import LullCore

/// The no-Developer-ID model: peers are pinned by identifier + cdhash of the
/// installed build. Uses copies of system binaries re-signed ad-hoc, exactly
/// as an attacker would make a look-alike.
final class PeerPinTests: XCTestCase {
    var dir = ""

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "lull-pin-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o755)
    }

    @discardableResult
    func sh(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Copies a system binary and ad-hoc signs it with `identifier`.
    func adHocCopy(of source: String, as name: String, identifier: String, thin: Bool) throws -> String {
        let path = "\(dir)/\(name)"
        if thin {
            var arch = utsname()
            uname(&arch)
            let machine = withUnsafeBytes(of: &arch.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            // System binaries ship arm64e on Apple Silicon.
            let slice = machine == "arm64" ? "arm64e" : machine
            XCTAssertEqual(sh("/usr/bin/lipo", [source, "-thin", slice, "-output", path]), 0, "lipo \(slice)")
        } else {
            try FileManager.default.copyItem(atPath: source, toPath: path)
        }
        XCTAssertEqual(sh("/usr/bin/codesign", ["-f", "-s", "-", "-i", identifier, path]), 0, "codesign")
        return path
    }

    func testLookAlikeWithSameIdentifierIsRefused() throws {
        for thin in [true, false] {
            let real = try adHocCopy(of: "/bin/ls", as: "real-\(thin)", identifier: "au.com.nickit.lull", thin: thin)
            let fake = try adHocCopy(of: "/bin/cat", as: "fake-\(thin)", identifier: "au.com.nickit.lull", thin: thin)
            let pin = CodeSigningRequirement.pinned(identifier: "au.com.nickit.lull", installedPath: real, requiredOwner: getuid())
            XCTAssertTrue(pin.pinned, pin.problem ?? "")
            XCTAssertTrue(pin.requirement.contains("cdhash H\""), pin.requirement)
            XCTAssertTrue(CodeSigningRequirement.isValid(pin.requirement))
            XCTAssertTrue(CodeSigningRequirement.code(at: real, satisfies: pin.requirement), "the installed build passes (thin=\(thin))")
            XCTAssertFalse(CodeSigningRequirement.code(at: fake, satisfies: pin.requirement), "look-alike refused (thin=\(thin))")
            // What identifier-only pinning (no Team ID, no cdhash) would have allowed:
            XCTAssertTrue(CodeSigningRequirement.code(at: fake, satisfies: #"identifier "au.com.nickit.lull""#))
        }
    }

    func testRebuiltPeerGetsNewPin() throws {
        let path = try adHocCopy(of: "/bin/ls", as: "app", identifier: "au.com.nickit.lull", thin: true)
        let before = try XCTUnwrap(CodeSigningRequirement.cdhash(ofCodeAt: path))
        XCTAssertEqual(before.count, 40)
        // An upgrade replaces the binary; the next pin follows it.
        try FileManager.default.removeItem(atPath: path)
        _ = try adHocCopy(of: "/bin/cat", as: "app", identifier: "au.com.nickit.lull", thin: true)
        XCTAssertNotEqual(CodeSigningRequirement.cdhash(ofCodeAt: path), before)
    }

    func testFallsBackWhenPeerUnreadableOrInsecure() throws {
        let missing = CodeSigningRequirement.pinned(identifier: "x.y", installedPath: dir + "/nope", requiredOwner: getuid())
        XCTAssertFalse(missing.pinned)
        XCTAssertEqual(missing.requirement, #"identifier "x.y""#)

        let unsigned = dir + "/unsigned"
        FileManager.default.createFile(atPath: unsigned, contents: Data("#!/bin/sh\n".utf8))
        XCTAssertFalse(CodeSigningRequirement.pinned(identifier: "x.y", installedPath: unsigned, requiredOwner: getuid()).pinned)

        // A user-writable install folder could be swapped out under us: don't trust it.
        let real = try adHocCopy(of: "/bin/ls", as: "real", identifier: "x.y", thin: true)
        chmod(dir, 0o777)
        let loose = CodeSigningRequirement.pinned(identifier: "x.y", installedPath: real, requiredOwner: getuid())
        XCTAssertFalse(loose.pinned)
        XCTAssertTrue(loose.problem?.contains("writable") ?? false, loose.problem ?? "")
        chmod(dir, 0o755)
        XCTAssertTrue(CodeSigningRequirement.pinned(identifier: "x.y", installedPath: real, requiredOwner: getuid()).pinned)
        XCTAssertFalse(
            CodeSigningRequirement.pinned(identifier: "x.y", installedPath: real, requiredOwner: getuid() + 1).pinned,
            "owned by someone other than root/the expected owner")
    }

    func testRequirementStrings() {
        XCTAssertEqual(CodeSigningRequirement.string(identifier: "a.b", teamID: nil), #"identifier "a.b""#)
        XCTAssertEqual(
            CodeSigningRequirement.string(identifier: "a.b", teamID: nil, cdhash: String(repeating: "ab", count: 20)),
            #"identifier "a.b" and cdhash H"abababababababababababababababababababab""#)
        let withTeam = CodeSigningRequirement.string(identifier: "a.b", teamID: "ABCDE12345", cdhash: String(repeating: "0", count: 40))
        XCTAssertTrue(withTeam.contains(#"certificate leaf[subject.OU] = "ABCDE12345""#))
        XCTAssertTrue(CodeSigningRequirement.isValid(withTeam))
    }
}
