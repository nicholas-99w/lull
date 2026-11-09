import Foundation
import LullCore

/// One call to the portal (lull-portal contract/PORTAL_API.md). Values carry secrets (the
/// enrolment secret, the device token): never log or interpolate them.
public enum PortalRequest: Equatable, Sendable {
    case register(PortalAPI.RegisterRequest)
    case fetchSettings(token: String, etag: String?)
    case checkIn(token: String, PortalAPI.CheckIn)

    /// Safe to log.
    public var kind: String {
        switch self {
        case .register: return "register"
        case .fetchSettings: return "settings"
        case .checkIn: return "checkin"
        }
    }
}

public enum PortalOutcome: Equatable, Sendable {
    case registered(PortalAPI.RegisterResponse)
    case settings(PortalAPI.SettingsPayload, etag: String?)
    case notModified
    case checkedIn
    /// 401: wrong enrolment secret, or the device token is no longer valid.
    case unauthorized
    /// 409 on register: the serial is registered and IT hasn't reset it.
    case conflict
    /// 410 on settings/check-in: IT de-registered this Mac in the portal.
    case deregistered
    /// Network, TLS or server problem. Safe to log (no secrets).
    case failed(String)
}

/// Sends one request. Seam so tests never touch the network.
public protocol PortalTransport: AnyObject {
    /// Calls `completion` exactly once, on an arbitrary queue.
    func send(_ request: URLRequest, completion: @escaping (Result<(HTTPURLResponse, Data), Error>) -> Void)
}

public final class PortalClient {
    let transport: PortalTransport
    public static let timeout: TimeInterval = 20

    public init(transport: PortalTransport) {
        self.transport = transport
    }

    public func perform(_ request: PortalRequest, baseURL: URL, completion: @escaping (PortalOutcome) -> Void) {
        let urlRequest: URLRequest
        do {
            urlRequest = try Self.urlRequest(for: request, baseURL: baseURL)
        } catch {
            completion(.failed("could not encode \(request.kind) request"))
            return
        }
        transport.send(urlRequest) { result in
            switch result {
            case .success(let (response, data)): completion(Self.outcome(for: request, response: response, data: data))
            case .failure(let error): completion(.failed(Self.describe(error)))
            }
        }
    }

    static func url(_ path: String, base: URL) -> URL {
        // Base URLs may carry a path prefix (https://host/lull); keep it.
        var b = base.absoluteString
        if !b.hasSuffix("/") { b += "/" }
        return URL(string: b + path)!
    }

    public static func urlRequest(for request: PortalRequest, baseURL: URL) throws -> URLRequest {
        let encoder = PortalAPI.encoder()
        var r: URLRequest
        switch request {
        case .register(let body):
            r = URLRequest(url: url(PortalAPI.Path.register, base: baseURL))
            r.httpMethod = "POST"
            r.httpBody = try encoder.encode(body)
        case .fetchSettings(let token, let etag):
            r = URLRequest(url: url(PortalAPI.Path.settings, base: baseURL))
            r.httpMethod = "GET"
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        case .checkIn(let token, let body):
            r = URLRequest(url: url(PortalAPI.Path.checkIn, base: baseURL))
            r.httpMethod = "POST"
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.httpBody = try encoder.encode(body)
        }
        if r.httpBody != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("lulld/\(LullConstants.version)", forHTTPHeaderField: "User-Agent")
        // Our own ETag handling decides what's fresh; never a cached copy.
        r.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        r.timeoutInterval = timeout
        return r
    }

    public static func outcome(for request: PortalRequest, response: HTTPURLResponse, data: Data) -> PortalOutcome {
        let status = response.statusCode
        if status == 401 { return .unauthorized }
        let decoder = PortalAPI.decoder()
        switch (request, status) {
        case (.register, 200):
            guard let r = try? decoder.decode(PortalAPI.RegisterResponse.self, from: data),
                !r.deviceToken.isEmpty, !r.deviceId.isEmpty
            else { return .failed("register: unexpected response body") }
            return .registered(r)
        case (.register, 409):
            return .conflict
        case (.fetchSettings, 200):
            guard let p = try? decoder.decode(PortalAPI.SettingsPayload.self, from: data) else {
                return .failed("settings: unexpected response body")
            }
            return .settings(p, etag: response.value(forHTTPHeaderField: "ETag"))
        case (.fetchSettings, 304):
            return .notModified
        case (.fetchSettings, 410), (.checkIn, 410):
            return .deregistered
        case (.checkIn, 200), (.checkIn, 204):
            return .checkedIn
        default:
            return .failed("\(request.kind): HTTP \(status)")
        }
    }

    /// Short, secret-free description of a transport error.
    static func describe(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == NSURLErrorDomain {
            switch e.code {
            case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
                NSURLErrorSecureConnectionFailed:
                return "TLS failed (\(e.code)): certificate not trusted, or the clock is far off"
            case NSURLErrorNotConnectedToInternet: return "offline"
            case NSURLErrorTimedOut: return "timed out"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "portal host not found"
            case NSURLErrorCannotConnectToHost: return "cannot connect to portal"
            case NSURLErrorHTTPTooManyRedirects, NSURLErrorRedirectToNonExistentLocation: return "redirect refused"
            default: return "network error \(e.code)"
            }
        }
        return "\(e.domain) \(e.code)"
    }
}

/// URLSession with no cookies, no cache and no credential storage. TLS uses
/// the system trust store (so a Jamf-deployed CA works) and is never relaxed.
/// Redirects are refused: the bearer token must only go to `Portal.URL`.
/// VERIFY on a managed Mac (Docs/TESTING.md H1, H15): that URLSession in a root
/// LaunchDaemon uses the system trust store (Jamf-deployed CA) and system proxy.
public final class URLSessionPortalTransport: NSObject, PortalTransport, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.timeoutIntervalForRequest = PortalClient.timeout
        c.timeoutIntervalForResource = PortalClient.timeout * 2
        c.waitsForConnectivity = false
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    public override init() { super.init() }

    public func send(_ request: URLRequest, completion: @escaping (Result<(HTTPURLResponse, Data), Error>) -> Void) {
        session.dataTask(with: request) { data, response, error in
            if let error { return completion(.failure(error)) }
            guard let http = response as? HTTPURLResponse else {
                return completion(.failure(URLError(.badServerResponse)))
            }
            completion(.success((http, data ?? Data())))
        }.resume()
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // nil = don't follow; the 3xx is returned and reported as an HTTP error.
        completionHandler(nil)
    }
}
