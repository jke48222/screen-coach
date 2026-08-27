import Foundation
import ScreenCoachCore

/// Loads the exclusion list from disk and reloads it the instant it changes.
///
/// Hot reload is a privacy requirement, not a convenience. If excluding your
/// bank means quitting and relaunching the coach, the realistic behaviour is
/// that nobody does it and the list stays at its defaults forever. Editing the
/// file has to take effect before the next query, which means watching it.
///
/// The file is plain text and lives somewhere the user can find it, so the
/// privacy control is auditable. A protection you cannot read is a promise,
/// not a mechanism.
public final class ExclusionStore {

    public private(set) var list: ExclusionList
    public let url: URL

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private let lock = NSLock()

    /// Fired after a reload so the UI can show the new count.
    public var onChange: ((ExclusionList) -> Void)?

    public init(url: URL? = nil) {
        let resolved = url ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/screencoach/exclusions.conf")
        self.url = resolved
        self.list = ExclusionList.defaults
        loadOrSeed()
        watch()
    }

    deinit { stopWatching() }

    // MARK: - Loading

    private func loadOrSeed() {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // First run: write the defaults out so the user can see exactly
            // what is being excluded rather than having to trust a claim.
            try? ExclusionList.defaults.serialized().write(to: url, atomically: true,
                                                           encoding: .utf8)
            lock.lock(); list = ExclusionList.defaults; lock.unlock()
            return
        }
        let parsed = ExclusionList.parse(text)
        lock.lock()
        // An empty or unparseable file means the defaults, never "allow
        // everything". Failing open here would silently disable the whole
        // protection the moment someone truncated the file.
        list = parsed.rules.isEmpty ? .defaults : parsed
        lock.unlock()
    }

    public func reload() {
        loadOrSeed()
        onChange?(current)
    }

    public var current: ExclusionList {
        lock.lock(); defer { lock.unlock() }
        return list
    }

    // MARK: - The gate

    /// The single question every capture path must ask first.
    public func check(bundleID: String?, windowTitle: String?) -> ExclusionList.Verdict {
        current.check(bundleID: bundleID, windowTitle: windowTitle)
    }

    // MARK: - Watching

    private func watch() {
        stopWatching()
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = s.data
            self.loadOrSeed()
            self.onChange?(self.current)
            // Editors replace rather than write in place, which invalidates
            // the descriptor. Re-arm on rename or delete or the watch dies
            // after the first save from any real editor.
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.watch() }
            }
        }
        s.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        s.resume()
        source = s
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
    }

    public var statusLine: String {
        let l = current
        let bundles = l.rules.filter { $0.kind == .bundleID }.count
        let titles = l.rules.filter { $0.kind == .titleContains }.count
        return "\(bundles) apps, \(titles) title patterns excluded"
    }
}
