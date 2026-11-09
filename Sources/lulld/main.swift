import Foundation
import LullCore
import LullDaemonKit

// lulld: root LaunchDaemon. Everything runs on one serial queue, which owns
// the DaemonEngine, so the engine needs no locking.
//
// DEV SAFETY: never run this on a daily-driver Mac (Docs/DEVELOPMENT.md > Dev safety). With the agent
// installed it locks the screen; use Scripts/dev-install.sh on a test Mac only.

#if !DEBUG
    // Refuse debugger attachment in Release.
    Hardening.denyDebuggerAttach()
#endif

let queue = DispatchQueue(label: LullConstants.daemonLabel)
var arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    var text = "usage: lulld [--version]"
    #if DEBUG
        text += " [--time-offset <seconds>] [--dev-config <plist>] [--state-dir <dir>] [--log-dir <dir>] [--portal-url <url>]"
    #endif
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(64)
}

func takeValue(_ flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag) else { return nil }
    guard i + 1 < arguments.count else { usage() }
    let v = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return v
}

if arguments.contains("--version") {
    print("lulld \(LullConstants.version)\(DaemonEngine.isDebugBuild ? " (DEBUG)" : "")")
    exit(0)
}

var paths = DaemonPaths.production
let clock = SystemClockSource()
#if DEBUG
    var timeOffset: TimeInterval?
    if let v = takeValue("--time-offset") {
        guard let d = Double(v) else { usage() }
        timeOffset = d
    }
    // A local test portal (http allowed), e.g. http://localhost:8080.
    var portalURLOverride: URL?
    if let v = takeValue("--portal-url") {
        guard let u = URL(string: v), u.scheme == "http" || u.scheme == "https", u.host != nil else { usage() }
        portalURLOverride = u
    }
    let devConfig = takeValue("--dev-config") ?? DebugConfigSource.defaultDevPlistPath
    if let dir = takeValue("--state-dir") {
        paths = DaemonPaths(stateDirectory: dir, logDirectory: paths.logDirectory, requiredOwnerUID: getuid())
    }
    if let dir = takeValue("--log-dir") {
        paths = DaemonPaths(
            stateDirectory: paths.stateDirectory, logDirectory: dir, requiredOwnerUID: paths.requiredOwnerUID)
    }
    let configSource: ConfigSource = DebugConfigSource(
        devPlistPath: devConfig, fallback: ManagedPreferencesSource(requireForced: false))
#else
    // Release: only keys enforced by a configuration profile count.
    let configSource: ConfigSource = ManagedPreferencesSource(requireForced: true)
#endif
guard arguments.isEmpty else { usage() }

if getuid() != 0 {
    FileHandle.standardError.write(Data("lulld: warning: not running as root\n".utf8))
}
umask(0o022)

let log = JSONLinesEventLog(path: paths.logPath)
let syncer = NetworkTimeSync(clock: clock)
let portalClient = PortalClient(transport: URLSessionPortalTransport())
var engine: DaemonEngine!
var watcher: DirectoryWatcher?
var signalSources: [DispatchSourceSignal] = []
var tickTimer: DispatchSourceTimer?
var hub: AgentHub!
var listener: NSXPCListener?

func startSyncIfDue() {
    guard engine.syncDue else { return }
    engine.syncStarted()
    syncer.sync(servers: engine.timeServers, preferAuthenticated: engine.syncPrefersAuthenticated) { result in
        queue.async { engine.syncFinished(result) }
    }
}

// Parent portal: one request at a time; the engine decides what and applies
// the result on our queue. Network trouble never affects enforcement.
func startPortalIfDue() {
    guard let (request, baseURL) = engine.nextPortalRequest() else { return }
    portalClient.perform(request, baseURL: baseURL) { outcome in
        queue.async { engine.portalFinished(request, outcome) }
    }
}

queue.async {
    engine = DaemonEngine(
        .init(clock: clock, configSource: configSource, store: JSONStateStore(paths: paths), log: log, paths: paths))
    #if DEBUG
        if let timeOffset { engine.debugTimeOffset = timeOffset }
        if let portalURLOverride { engine.debugPortalURL = portalURLOverride }
    #endif
    // Attempt a sync immediately at start.
    startSyncIfDue()

    // XPC: agents connect to our Mach service (declared in the LaunchDaemon plist).
    // Agents must be the exact Lull.app build installed in the root-owned
    // install folder (cdhash pin; no Developer ID needed). The listener-level
    // identifier check is a cheap first gate; AgentHub applies the pin per connection.
    hub = AgentHub(
        .init(
            queue: queue, clock: clock, sessions: DynamicStoreSessions(), users: SystemUserDirectory(),
            runner: ProcessRunner(), log: log,
            peerPin: {
                CodeSigningRequirement.pinned(
                    identifier: CodeSigningRequirement.agentIdentifier, installedPath: CodeSigningRequirement.installedAgentPath)
            }),
        engine: engine)
    let gate = CodeSigningRequirement.string(
        identifier: CodeSigningRequirement.agentIdentifier, teamID: CodeSigningRequirement.ownTeamIdentifier())
    precondition(CodeSigningRequirement.isValid(gate), "invalid code signing requirement")
    let l = NSXPCListener(machServiceName: LullConstants.daemonLabel)
    l.setConnectionCodeSigningRequirement(gate)
    l.delegate = hub
    l.resume()
    listener = l
    let startupPin = CodeSigningRequirement.pinned(
        identifier: CodeSigningRequirement.agentIdentifier, installedPath: CodeSigningRequirement.installedAgentPath)
    log.event(
        "xpc_listening", category: .xpc,
        fields: [
            "service": LullConstants.daemonLabel, "agentRequirement": startupPin.requirement, "pinned": startupPin.pinned,
            "problem": startupPin.problem ?? "",
        ])

    watcher = DirectoryWatcher(path: paths.managedPreferencesDirectory, queue: queue) {
        engine.reloadConfig()
    }

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
    timer.setEventHandler {
        engine.tick()
        hub.tick()
        startSyncIfDue()
        startPortalIfDue()
    }
    timer.resume()
    tickTimer = timer

    // launchd sends SIGTERM on shutdown/bootout: persist lastKnownTrusted first.
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
        src.setEventHandler {
            engine.shutdown()
            exit(0)
        }
        src.resume()
        signalSources.append(src)
    }
}

dispatchMain()
