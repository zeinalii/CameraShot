import Darwin
import Foundation

final class FileExploreWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private let queue = DispatchQueue(label: "camerashot.file-explore-watcher", qos: .utility)

    func start(url: URL, onChange: @escaping () -> Void) -> Bool {
        stop()

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
            queue: queue
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }

        fileDescriptor = fd
        self.source = source
        source.resume()
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }

    deinit {
        stop()
    }
}
