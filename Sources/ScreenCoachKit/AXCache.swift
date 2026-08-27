import AppKit
import ApplicationServices
import ScreenCoachCore

/// Keeps the frontmost app's accessibility tree warm and ready.
///
/// Phase 0 made this mandatory rather than optional. Walking an app's tree for
/// the first time costs 45–220 ms — the *target* app has to build and vend it —
/// while every walk after that costs 1–21 ms. The coach's exact situation is
/// "user just switched to an app and pressed the hotkey", which is the cold
/// path, so extracting on the hotkey would blow the 80 ms budget on every app
/// worth teaching.
///
/// Warmth also decays: Logic Pro drifted 21 → 64 ms after ten idle seconds and
/// Calendar went fully cold at 120 ms. So focus-change extraction alone is not
/// enough; a low-rate heartbeat holds the tree warm between queries.
///
/// Three things drive a refresh:
///   * **Focus change** — a different app or window is in front.
///   * **AXObserver events** — the window moved, resized, or its focus moved,
///     so cached bounds are stale.
///   * **Heartbeat** — nothing happened, but warmth decays anyway.
public final class AXCache {

    public struct Entry {
        public let snapshot: AXTreeSnapshot
        public let capturedAtNs: UInt64
        public var ageMs: Double { Mono.msSince(capturedAtNs) }
    }

    /// Heartbeat interval. Chosen from the measured decay curve: trees are
    /// still near-warm at 5 s and clearly cooling by 10 s, so refreshing every
    /// 3 s keeps the fast path fast without hammering other apps.
    public var heartbeat: TimeInterval = 3.0

    /// Skip heartbeat walks while the user has not touched the machine.
    ///
    /// The heartbeat exists so the hotkey lands on a warm tree — but a hotkey
    /// press requires a human at the keyboard, and if nobody has produced an
    /// input event in over a minute, no press is imminent. Walking a heavy
    /// app's tree every three seconds through lunch is pure battery burn.
    /// Event- and focus-driven refreshes are exempt: they only fire when
    /// something is actually happening. The cost of the trade is one
    /// cold-ish serve (~45–220 ms, once) if the user returns and summons
    /// within the very first seconds.
    public var idleBackoffEnabled = true
    public var userIdleThreshold: TimeInterval = 60

    /// Beyond this the cached tree is treated as untrustworthy and re-read
    /// synchronously. Generous, because bounds only change on events we
    /// already observe.
    public var maxServeAgeMs: Double = 5_000

    public var limits = AXExtractor.Limits.default

    /// Asked before any tree is read. Returning a reason means "do not touch
    /// this app at all".
    ///
    /// Gating only the screenshot was not enough, and testing found it: an
    /// accessibility tree contains the *content*, not just the controls. A
    /// query against Messages happily surfaced the text of a conversation as a
    /// match candidate — no frame was ever captured, and the private data
    /// leaked anyway.
    ///
    /// So exclusion means excluded: no capture, and no tree. The coach cannot
    /// help you inside your password manager, which is the correct trade.
    public var exclusionCheck: ((_ bundleID: String?, _ title: String?) -> String?)?

    /// Set when the last refresh was refused, so the UI can explain itself
    /// rather than looking broken.
    public private(set) var lastExclusionReason: String?

    private let queue = DispatchQueue(label: "coach.axcache", qos: .userInitiated)
    private let lock = NSLock()
    private var entry: Entry?
    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var timer: DispatchSourceTimer?
    private var running = false
    private var lastRefreshRequestNs: UInt64 = 0
    private var targetPID: pid_t = 0
    private var pinnedPID: pid_t = 0

    /// The app the coach is about, which is never the coach.
    ///
    /// `NSWorkspace.frontmostApplication` answers "who is in front right now",
    /// and once this process has an NSApplication that can briefly be us — on
    /// launch, and whenever the command bar takes keyboard focus. Asking about
    /// ourselves returns a process with no window, so the tree comes back
    /// empty exactly when the user is typing their question.
    ///
    /// Remembering the last frontmost app that was not us is the fix, and it
    /// is also the semantically right answer: the query is about the app the
    /// user was working in, not about the input box they are typing into.
    private func resolveTarget() -> NSRunningApplication? {
        if pinnedPID != 0, let pinned = NSRunningApplication(processIdentifier: pinnedPID),
           !pinned.isTerminated { return pinned }
        let me = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != me {
            targetPID = front.processIdentifier
            return front
        }
        if targetPID != 0, let remembered = NSRunningApplication(processIdentifier: targetPID),
           !remembered.isTerminated {
            return remembered
        }
        // Nothing remembered yet: fall back to the frontmost regular app that
        // is not us, which is what the user would point at anyway.
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && !$0.isTerminated
                && $0.processIdentifier != me && $0.isActive
        }
    }

    /// Force the cache to follow one app regardless of focus. Used by the
    /// self-test so the pipeline can be exercised against an app that is not
    /// in front; the product itself always follows focus.
    public func pin(to pid: pid_t) {
        lock.lock(); pinnedPID = pid; entry = nil; lock.unlock()
        attachObserver()
        _ = extractNow(reason: "pinned")
    }

    public private(set) var refreshes = 0
    public private(set) var servedWarm = 0
    public private(set) var servedCold = 0

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + heartbeat, repeating: heartbeat,
                   leeway: .milliseconds(400))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if self.idleBackoffEnabled,
               Self.secondsSinceUserInput() > self.userIdleThreshold {
                return
            }
            self.refresh(reason: "heartbeat")
        }
        t.resume()
        timer = t

        attachObserver()
        refresh(reason: "start")
    }

    public func stop() {
        running = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        timer?.cancel()
        timer = nil
        detachObserver()
    }

    deinit { stop() }

    // MARK: - Serving

    /// The current tree. Serves the cache when it is fresh enough, otherwise
    /// pays for a synchronous extraction rather than handing back stale
    /// geometry — pointing confidently at where a button used to be is worse
    /// than being slow.
    public func tree() -> AXTreeSnapshot? {
        lock.lock()
        let cached = entry
        lock.unlock()

        if let cached, cached.ageMs <= maxServeAgeMs,
           cached.snapshot.pid == resolveTarget()?.processIdentifier {
            lock.lock(); servedWarm += 1; lock.unlock()
            return cached.snapshot
        }
        lock.lock(); servedCold += 1; lock.unlock()
        return extractNow()
    }

    public var cachedEntry: Entry? {
        lock.lock(); defer { lock.unlock() }
        return entry
    }

    // MARK: - Refresh

    @objc private func appActivated(_ note: Notification) {
        // Our own activation is not a focus change worth reacting to; it just
        // means the user summoned us.
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return
        }
        attachObserver()
        refresh(reason: "focus change")
    }

    /// Coalesces bursts. Stage Manager and window animations fire AX events in
    /// storms; re-walking a tree on each one would cost more than the cache
    /// saves.
    private func refresh(reason: String) {
        let now = Mono.nowNs()
        lock.lock()
        let tooSoon = Mono.ms(from: lastRefreshRequestNs, to: now) < 120
        if !tooSoon { lastRefreshRequestNs = now }
        lock.unlock()
        guard !tooSoon else { return }

        queue.async { [weak self] in
            guard let self, self.running else { return }
            _ = self.extractNow(reason: reason)
        }
    }

    @discardableResult
    private func extractNow(reason: String = "on demand") -> AXTreeSnapshot? {
        guard let app = resolveTarget() else { return nil }

        // The check runs on the bundle ID alone, before any AX call, because
        // the window title is itself something we would have to read the app
        // to learn. For title-pattern rules the window title comes from
        // CGWindowList rather than AX — same string, no tree walk.
        if let check = exclusionCheck {
            let title = Self.windowTitle(forPID: app.processIdentifier)
            if let why = check(app.bundleIdentifier, title) {
                lock.lock()
                entry = nil
                lastExclusionReason = why
                lock.unlock()
                return nil
            }
        }
        lock.lock(); lastExclusionReason = nil; lock.unlock()

        guard let snapshot = try? AXExtractor.windowTree(
            pid: app.processIdentifier,
            appName: app.localizedName ?? "pid \(app.processIdentifier)",
            bundleID: app.bundleIdentifier, limits: limits
        ) else { return nil }
        lock.lock()
        entry = Entry(snapshot: snapshot, capturedAtNs: Mono.nowNs())
        refreshes += 1
        lock.unlock()
        return snapshot
    }

    /// Frontmost window title for a pid, from the window server rather than
    /// from the accessibility API — so a title-pattern rule can be evaluated
    /// without reading the tree it is meant to prevent us reading.
    private static func windowTitle(forPID pid: pid_t) -> String? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let name = w[kCGWindowName as String] as? String, !name.isEmpty
            else { continue }
            return name
        }
        return nil
    }

    /// Seconds since the user last touched the machine, from the window
    /// server — no event tap needed. `kCGAnyInputEventType` is not a valid
    /// Swift enum case, so this takes the minimum over the input types that
    /// matter; any one of them recent means the user is here.
    static func secondsSinceUserInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown,
                                    .mouseMoved, .scrollWheel, .flagsChanged]
        return types.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
    }

    // MARK: - AXObserver

    /// Watches the frontmost app for the events that invalidate bounds. This
    /// layer never reads geometry — events only mean "the cache is stale",
    /// exactly the discipline WindowPet's Tier 2 settled on.
    private func attachObserver() {
        guard let pid = resolveTarget()?.processIdentifier,
              pid != observedPID else { return }
        detachObserver()

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AXCache>.fromOpaque(refcon).takeUnretainedValue()
            me.refresh(reason: "ax event")
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let created = obs else {
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var subscribed = false
        for note in [kAXWindowMovedNotification, kAXWindowResizedNotification,
                     kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification,
                     kAXFocusedUIElementChangedNotification] {
            if AXObserverAddNotification(created, app, note as CFString, refcon) == .success {
                subscribed = true
            }
        }
        guard subscribed else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        observedPID = pid
    }

    private func detachObserver() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(obs), .commonModes)
        }
        observer = nil
        observedPID = 0
    }

    public var statusLine: String {
        lock.lock(); defer { lock.unlock() }
        if let why = lastExclusionReason { return "excluded — \(why)" }
        guard let e = entry else { return "no tree cached" }
        return String(format: "%@ — %d nodes, %.0f ms old, %d refreshes, %d warm / %d cold",
                      e.snapshot.appName, e.snapshot.nodeCount, e.ageMs,
                      refreshes, servedWarm, servedCold)
    }
}
