import Foundation
import LullCore
import XCTest

@testable import LullDaemonKit

/// Opt-in end-to-end test against a running portal (the lull-portal repository), using
/// the real URLSession client. Skipped unless LULL_PORTAL_E2E_URL is set:
///
///   LULL_PORTAL_E2E_URL=http://localhost:8080 LULL_PORTAL_E2E_SECRET=change-me-enrolment-secret \
///   LULL_PORTAL_E2E_ADMIN_EMAIL=... LULL_PORTAL_E2E_ADMIN_PASSWORD=... \
///     swift test --filter PortalLiveTests
///
/// Only the engine runs (fake clock, temp state, no XPC/agent/supervisor), so
/// nothing can lock or sleep the Mac running it.
final class PortalLiveTests: XCTestCase {
    func testMacAndParentRoundTrip() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["LULL_PORTAL_E2E_URL"].flatMap(URL.init(string:)), let secret = env["LULL_PORTAL_E2E_SECRET"],
            let adminEmail = env["LULL_PORTAL_E2E_ADMIN_EMAIL"], let adminPassword = env["LULL_PORTAL_E2E_ADMIN_PASSWORD"]
        else {
            throw XCTSkip("set LULL_PORTAL_E2E_URL, _SECRET, _ADMIN_EMAIL and _ADMIN_PASSWORD to run against a live portal")
        }
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let student = "e2e\(suffix)"

        // The Mac.
        let h = Harness(at: Date(), config: configDict())
        h.device = FakeDevice(value: ("C02E2E\(suffix.uppercased())", UUID().uuidString))
        let data = try JSONSerialization.data(withJSONObject: [PortalCredentialFile.secretKey: secret])
        try SecureFile.writeAtomically(data, to: h.paths.portalEnrolmentPath, mode: 0o600)
        let e = h.start()
        e.debugPortalURL = base
        e.updateAgents([.init(uid: 501, username: student, connected: true, exempt: false)])
        let client = PortalClient(transport: URLSessionPortalTransport())

        func pump() -> [String] {
            var kinds: [String] = []
            while kinds.count < 10, let (request, url) = e.nextPortalRequest() {
                let done = DispatchSemaphore(value: 0)
                var outcome = PortalOutcome.failed("no response")
                client.perform(request, baseURL: url) {
                    outcome = $0
                    done.signal()
                }
                done.wait()
                kinds.append(request.kind)
                e.portalFinished(request, outcome)
            }
            return kinds
        }

        XCTAssertEqual(pump(), ["register", "settings", "checkin"], "\(String(describing: e.status.portal))")
        let deviceId = try XCTUnwrap(e.status.portal?.deviceId)
        XCTAssertEqual(e.status.portal?.settingsSource, "portal")
        XCTAssertEqual(e.activeConfig?.schedules.map(\.name), ["School night"], "a new Mac follows the school (profile)")
        XCTAssertNil(e.status.portal?.lastError)

        // IT creates the parent with the student linked; the parent sets a password with the one-time code.
        let it = Browser(base: base)
        try it.postForm("Login", ["email": adminEmail, "password": adminPassword])
        let parentEmail = "\(student)-parent@lull.test"
        let created = try it.postForm(
            "Admin/Users/Edit", ["name": "E2E Parent", "email": parentEmail, "role": "Parent", "students": student])
        let code = try XCTUnwrap(
            created.range(of: "[A-Z2-9]{4}-[A-Z2-9]{4}(?=</code>)", options: .regularExpression).map { String(created[$0]) },
            "setup code shown once after creating the user")
        let browser = Browser(base: base)
        try browser.postForm("Setup", ["email": parentEmail, "code": code, "pin": "E2e-Parent-Pass!", "confirm": "E2e-Parent-Pass!"])
        XCTAssertTrue(try browser.get("").contains(student), "the parent sees the Mac the student signed in to")
        try browser.postForm(
            "Device/\(deviceId)",
            [
                "schoolMode": "custom", "schoolStart": "21:00", "schoolEnd": "06:30",
                "weekendMode": "off", "weekendStart": "23:00", "weekendEnd": "08:00",
            ])
        XCTAssertTrue(try browser.get("Device/\(deviceId)").contains("Change pending"))

        // The Mac's next poll picks it up: the parent's school nights, and no weekend windows
        // (the profile's daily rule loses Sun–Thu to the custom window and Fri/Sat to the opt-out).
        h.jump(60)
        XCTAssertEqual(pump(), ["settings", "checkin"])
        XCTAssertEqual(e.activeConfig?.enabled, true)
        XCTAssertEqual(e.activeConfig?.schedules.map(\.name), ["School nights"])
        XCTAssertEqual(e.activeConfig?.schedules.first?.start, TimeOfDay(string: "21:00"))
        let page = try browser.get("Device/\(deviceId)")
        XCTAssertTrue(page.contains("Settings applied"))
        XCTAssertTrue(page.contains("Mac Serial Number:"))

        // "Lock down now" for 30 minutes, then "Release now". Done
        // as IT: this runs on the real clock, and parents can't lock down in school hours
        // (the portal's own tests cover that with a test clock).
        try it.postForm("Device/\(deviceId)?handler=Lock", ["minutes": "30"], page: "Device/\(deviceId)")
        h.jump(60)
        XCTAssertEqual(pump(), ["settings", "checkin"])
        XCTAssertEqual(e.status.phase, .locked)
        XCTAssertEqual(e.status.scheduleName, "Lock down")
        XCTAssertTrue(try browser.get("").contains("Locked down until"))
        try it.postForm("Device/\(deviceId)?handler=Release", [:], page: "Device/\(deviceId)")
        h.jump(60)
        XCTAssertEqual(pump(), ["settings", "checkin"])
        XCTAssertNotEqual(e.status.phase, .locked, "released")

        // IT de-registers the Mac: it falls back to its profile and stops calling the portal.
        try it.postForm("Device/\(deviceId)?handler=Deregister", ["confirm": "true"], page: "Device/\(deviceId)")
        h.jump(60)
        XCTAssertEqual(pump(), ["settings"])
        XCTAssertNotNil(e.status.portal?.deregisteredAt)
        XCTAssertNil(e.status.portal?.lastError)
        XCTAssertEqual(e.status.portal?.settingsSource, "profile")
        XCTAssertEqual(e.activeConfig?.schedules.map(\.name), ["School night"], "the profile's schedule again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.paths.portalEnrolmentPath))
        h.jump(120)
        XCTAssertEqual(pump(), [])
        XCTAssertTrue(try it.get("Admin/Devices").contains("De-registered"))
        print("live portal round trip OK: student \(student), device \(deviceId)")
    }
}

/// Minimal cookie-keeping HTTP client for the portal's forms.
private final class Browser {
    let base: URL
    let session: URLSession

    init(base: URL) {
        self.base = base
        // Ephemeral sessions keep cookies in memory for the session's lifetime.
        session = URLSession(configuration: .ephemeral)
    }

    func request(_ r: URLRequest) throws -> (Int, String) {
        let done = DispatchSemaphore(value: 0)
        var result: Result<(Int, String), Error> = .failure(URLError(.unknown))
        session.dataTask(with: r) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data ?? Data(), as: UTF8.self)))
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    func url(_ path: String) -> URL { path.isEmpty ? base : URL(string: path, relativeTo: base)! }

    func get(_ path: String) throws -> String {
        let (status, body) = try request(URLRequest(url: url(path)))
        XCTAssertEqual(status, 200, path)
        return body
    }

    /// GETs the form page for its antiforgery token, then POSTs (redirects followed).
    @discardableResult
    func postForm(_ path: String, _ fields: [String: String], page: String? = nil) throws -> String {
        let html = try get(page ?? path)
        let pattern = try NSRegularExpression(pattern: "name=\"__RequestVerificationToken\" type=\"hidden\" value=\"([^\"]+)\"")
        let match = try XCTUnwrap(pattern.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)))
        let token = String(html[Range(match.range(at: 1), in: html)!])
        var all = fields
        all["__RequestVerificationToken"] = token
        var r = URLRequest(url: url(path))
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        r.httpBody = Data(
            all.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
        let (status, body) = try request(r)
        XCTAssertEqual(status, 200, "\(path): \(body.prefix(300))")
        return body
    }
}
