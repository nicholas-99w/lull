import Foundation
import LullCore
import LullDaemonKit

// lullctl: admin CLI. Exit codes: 0 ok, 1 command failed (e.g. invalid
// config), 64 usage error (sysexits EX_USAGE).

var args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("lullctl: \(message)\n".utf8))
    exit(code)
}

func usage() -> Never {
    var text = """
        usage: lullctl <command> [options]

          status [--json] [--file <path>]     show daemon status
          validate-config <plist>             validate a config plist (exit 1 if invalid)
          hash-passphrase [--stdin] [--write] create an override passphrase hash
                                              --write stores it in \(LullConstants.overrideHashPath) (root)
          version                             print version

        """
    #if DEBUG
        text += """
              simulate --config <plist> --at <time> [--windows N]   (DEBUG builds only)
                                              evaluate the schedule at <time>: ISO 8601 with offset,
                                              or YYYY-MM-DDTHH:mm in the config's Timezone

            """
    #endif
    FileHandle.standardError.write(Data(text.utf8))
    exit(64)
}

func takeFlag(_ flag: String) -> Bool {
    guard let i = args.firstIndex(of: flag) else { return false }
    args.remove(at: i)
    return true
}

func takeValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count else { usage() }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func ensureNoExtraArgs() { if !args.isEmpty { usage() } }

func loadPlist(_ path: String) -> [String: Any] {
    guard FileManager.default.fileExists(atPath: path) else { fail("\(path): no such file") }
    guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
        fail("\(path): not a property list dictionary")
    }
    return dict
}

guard !args.isEmpty else { usage() }
let command = args.removeFirst()

switch command {
case "version", "--version":
    ensureNoExtraArgs()
    print("lullctl \(LullConstants.version)\(DaemonEngine.isDebugBuild ? " (DEBUG)" : "")")

case "status":
    let json = takeFlag("--json")
    let path = takeValue("--file") ?? LullConstants.statusPath
    ensureNoExtraArgs()
    StatusCommand.run(path: path, json: json)

case "validate-config":
    guard args.count == 1 else { usage() }
    let path = args.removeFirst()
    var raw = loadPlist(path)
    #if DEBUG
        raw.removeValue(forKey: LullConstants.debugTimeOffsetKey)
    #endif
    let result = ConfigParser().parse(raw)
    for issue in result.issues { print(issue) }
    if let config = result.config {
        print(
            "valid: \(config.schedules.count) schedule(s), \(config.dateExceptions.count) exception(s), timezone \(config.timeZoneIdentifier)"
        )
    } else {
        print("INVALID: \(result.errors.count) error(s)")
        exit(1)
    }

case "hash-passphrase":
    let fromStdin = takeFlag("--stdin")
    let write = takeFlag("--write")
    ensureNoExtraArgs()
    HashCommand.run(fromStdin: fromStdin, write: write)

#if DEBUG
    case "simulate":
        guard let configPath = takeValue("--config"), let at = takeValue("--at") else { usage() }
        var windows = 3
        if let v = takeValue("--windows") {
            guard let n = Int(v), n >= 0 else { usage() }
            windows = n
        }
        ensureNoExtraArgs()
        SimulateCommand.run(configPath: configPath, at: at, windows: windows)
#endif

default:
    usage()
}
