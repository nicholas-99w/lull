import Foundation
import LullCore
import Network

public struct TimeSyncError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public protocol TimeSyncing: AnyObject {
    /// Calls `completion` exactly once, on an arbitrary queue.
    /// - Parameter preferAuthenticated: try the TLS-authenticated HTTPS source
    ///   first (after SNTP proposed an implausible correction).
    func sync(
        servers: [String], preferAuthenticated: Bool, completion: @escaping (Result<TimeSyncSample, TimeSyncError>) -> Void)
}

/// SNTP against each configured server in order, then the HTTPS `Date` header
/// as a fallback for networks that block UDP 123. Network is only
/// ever used to *improve* time; failure leaves enforcement unchanged.
public final class NetworkTimeSync: TimeSyncing {
    let clock: ClockSource
    let queue = DispatchQueue(label: "\(LullConstants.daemonLabel).timesync")
    let timeout: TimeInterval
    /// HTTPS fallback endpoints (any well-known site with a correct Date header).
    let httpsFallbackURLs: [URL]

    public init(
        clock: ClockSource, timeout: TimeInterval = 3,
        httpsFallbackURLs: [URL] = [URL(string: "https://www.apple.com/")!]
    ) {
        self.clock = clock
        self.timeout = timeout
        self.httpsFallbackURLs = httpsFallbackURLs
    }

    public func sync(
        servers: [String], preferAuthenticated: Bool, completion: @escaping (Result<TimeSyncSample, TimeSyncError>) -> Void
    ) {
        queue.async {
            if preferAuthenticated {
                // HTTPS first; SNTP only if HTTPS is unreachable (its sample is
                // still bounded by the drift allowance in TrustedClock).
                self.tryHTTPS(self.httpsFallbackURLs[...], errors: []) { result in
                    if case .failure(let e) = result {
                        self.trySNTP(servers[...], errors: [e.description], https: false, completion: completion)
                    } else {
                        completion(result)
                    }
                }
            } else {
                self.trySNTP(servers[...], errors: [], https: true, completion: completion)
            }
        }
    }

    private func trySNTP(
        _ remaining: ArraySlice<String>, errors: [String], https: Bool,
        completion: @escaping (Result<TimeSyncSample, TimeSyncError>) -> Void
    ) {
        guard let server = remaining.first else {
            if https {
                tryHTTPS(httpsFallbackURLs[...], errors: errors, completion: completion)
            } else {
                completion(.failure(TimeSyncError(errors.joined(separator: "; "))))
            }
            return
        }
        SNTPQuery(server: server, clock: clock, queue: queue, timeout: timeout).run { result in
            switch result {
            case .success(let sample): completion(.success(sample))
            case .failure(let e):
                self.trySNTP(remaining.dropFirst(), errors: errors + ["\(server): \(e)"], https: https, completion: completion)
            }
        }
    }

    private func tryHTTPS(
        _ remaining: ArraySlice<URL>, errors: [String], completion: @escaping (Result<TimeSyncSample, TimeSyncError>) -> Void
    ) {
        guard let url = remaining.first else {
            completion(.failure(TimeSyncError(errors.joined(separator: "; "))))
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout * 2)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: .ephemeral)
        let sentAt = clock.continuousSeconds
        session.dataTask(with: request) { _, response, error in
            let receivedAt = self.clock.continuousSeconds
            session.finishTasksAndInvalidate()
            self.queue.async {
                let host = url.host ?? url.absoluteString
                if let http = response as? HTTPURLResponse, let header = http.value(forHTTPHeaderField: "Date"),
                    let sample = HTTPDateHeader.sample(header: header, sentAt: sentAt, receivedAt: receivedAt, server: "https://\(host)")
                {
                    completion(.success(sample))
                } else {
                    let why = error.map { $0.localizedDescription } ?? "no usable Date header"
                    self.tryHTTPS(remaining.dropFirst(), errors: errors + ["https://\(host): \(why)"], completion: completion)
                }
            }
        }.resume()
    }
}

/// One SNTP request/response over UDP with a timeout.
final class SNTPQuery {
    let server: String
    let clock: ClockSource
    let queue: DispatchQueue
    let timeout: TimeInterval
    private var connection: NWConnection?
    private var finished = false
    private var completion: ((Result<TimeSyncSample, TimeSyncError>) -> Void)?

    init(server: String, clock: ClockSource, queue: DispatchQueue, timeout: TimeInterval) {
        self.server = server
        self.clock = clock
        self.queue = queue
        self.timeout = timeout
    }

    /// Must be called on `queue`. The query keeps itself alive until it finishes.
    func run(_ completion: @escaping (Result<TimeSyncSample, TimeSyncError>) -> Void) {
        self.completion = completion
        let nonce = UInt64.random(in: 1...UInt64.max)
        let conn = NWConnection(host: NWEndpoint.Host(server), port: 123, using: .udp)
        connection = conn
        var sentAt: TimeInterval = 0
        conn.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                sentAt = clock.continuousSeconds
                conn.send(
                    content: Data(SNTPPacket.request(nonce: nonce)),
                    completion: .contentProcessed { error in
                        if let error { self.finish(.failure(TimeSyncError("send: \(error)"))) }
                    })
                conn.receiveMessage { data, _, _, error in
                    let receivedAt = self.clock.continuousSeconds
                    guard let data, error == nil else {
                        self.finish(.failure(TimeSyncError("receive: \(error.map { "\($0)" } ?? "no data")")))
                        return
                    }
                    let parsed = SNTPPacket.parseResponse(
                        Array(data), nonce: nonce, sentAt: sentAt, receivedAt: receivedAt, server: self.server)
                    self.finish(parsed.mapError { TimeSyncError($0.description) })
                }
            case .failed(let error):
                finish(.failure(TimeSyncError("connection: \(error)")))
            case .waiting(let error):
                // No route (e.g. offline): don't wait for the network to come back.
                finish(.failure(TimeSyncError("unreachable: \(error)")))
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            finish(.failure(TimeSyncError("timed out after \(Int(timeout))s")))
        }
    }

    private func finish(_ result: Result<TimeSyncSample, TimeSyncError>) {
        guard !finished else { return }
        finished = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let c = completion
        completion = nil
        c?(result)
    }
}
