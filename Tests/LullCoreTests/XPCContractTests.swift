import XCTest

@testable import LullCore

final class XPCContractTests: XCTestCase {
    func testRequirementStrings() {
        XCTAssertEqual(CodeSigningRequirement.string(identifier: "au.com.nickit.lull", teamID: nil), #"identifier "au.com.nickit.lull""#)
        XCTAssertEqual(CodeSigningRequirement.string(identifier: "au.com.nickit.lull", teamID: ""), #"identifier "au.com.nickit.lull""#)
        XCTAssertEqual(
            CodeSigningRequirement.string(identifier: "au.com.nickit.lulld", teamID: "ABCDE12345"),
            #"identifier "au.com.nickit.lulld" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#)
        XCTAssertEqual(CodeSigningRequirement.installedAgentPath, "/Library/Application Support/Lull/Lull.app")
        XCTAssertEqual(CodeSigningRequirement.installedDaemonPath, "/Library/Application Support/Lull/bin/lulld")
    }

    func testRequirementsCompile() {
        for team in [nil, "ABCDE12345"] {
            for id in [CodeSigningRequirement.agentIdentifier, CodeSigningRequirement.daemonIdentifier] {
                XCTAssertTrue(CodeSigningRequirement.isValid(CodeSigningRequirement.string(identifier: id, teamID: team)))
            }
        }
        XCTAssertFalse(CodeSigningRequirement.isValid("identifier and nonsense ("))
    }

    func testIdentifiersMatchBundleIDs() {
        XCTAssertEqual(CodeSigningRequirement.agentIdentifier, "au.com.nickit.lull")
        XCTAssertEqual(CodeSigningRequirement.daemonIdentifier, "au.com.nickit.lulld")
    }

    func testOwnTeamIDIsNilForAdHocTestRunner() {
        // The test runner has no Team ID in our signature model, so pins are identifier + cdhash only.
        XCTAssertNil(CodeSigningRequirement.ownTeamIdentifier())
    }

    func testPayloadRoundTrips() {
        let state = DisplayState(
            phase: .locked, trustedNow: Date(timeIntervalSince1970: 1_800_000_000.5), windowEnd: Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertEqual(XPCCoding.decode(DisplayState.self, from: XPCCoding.encode(state)), state)
        for r: OverrideResult in [
            .granted(until: Date(timeIntervalSince1970: 5)), .rejected(attemptsRemaining: 2),
            .lockedOut(until: Date(timeIntervalSince1970: 9)), .unavailable("x"),
        ] {
            XCTAssertEqual(XPCCoding.decode(OverrideResult.self, from: XPCCoding.encode(r)), r)
        }
        XCTAssertNil(XPCCoding.decode(DisplayState.self, from: Data("junk".utf8)))
        XCTAssertNil(XPCCoding.decode(DisplayState.self, from: nil))
    }
}
