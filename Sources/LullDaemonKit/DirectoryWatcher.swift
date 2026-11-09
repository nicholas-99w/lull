import Darwin
import Foundation

/// Fires `onChange` when entries in a directory are added, removed or renamed.
/// Used on `/Library/Managed Preferences` so profile changes apply right away;
/// the engine also polls every 5s, so a missed event (or a directory that
/// doesn't exist yet) only delays a reload, never loses it.
public final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?

    public init?(path: String, queue: DispatchQueue, onChange: @escaping () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        src.setEventHandler(handler: onChange)
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }
}
