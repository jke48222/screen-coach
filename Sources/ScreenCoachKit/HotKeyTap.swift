import AppKit
import CoreGraphics
import ScreenCoachCore

/// Listen-only global hotkey via `CGEventTap`.
///
/// Chosen over Carbon's `RegisterEventHotKey` for one measurement-critical
/// reason: the tap hands over the original `CGEvent`, and
/// `CGEventGetTimestamp` on it is the moment the *hardware* event entered the
/// system, in raw mach units. Timing from there instead of from "when my
/// callback ran" means the reported hotkey→frame figure includes event
/// delivery — which is part of what the user feels, and is exactly the term a
/// naive harness hides from itself.
///
/// `.listenOnly` matters too: the tap observes and never consumes, so the
/// shortcut still reaches whatever app is in front and we cannot wedge the
/// user's keyboard if this process hangs.
public final class HotKeyTap {

    public struct Binding: Equatable {
        public let keyCode: UInt16
        public let flags: CGEventFlags

        public init(keyCode: UInt16, flags: CGEventFlags) {
            self.keyCode = keyCode
            self.flags = flags
        }

        /// Option-Space, matching WindowPet's default summon.
        public static let optionSpace = Binding(keyCode: 49, flags: .maskAlternate)

        static let significant: CGEventFlags = [
            .maskCommand, .maskShift, .maskAlternate, .maskControl,
        ]

        func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
            keyCode == self.keyCode
                && flags.intersection(Self.significant) == self.flags.intersection(Self.significant)
        }
    }

    /// Fired with the hardware event's timestamp, already on the `Mono` axis.
    public var onHotKey: ((UInt64) -> Void)?

    /// Fired when the key is released. Push-to-talk is a *hold*, so the turn
    /// is bracketed by these two rather than triggered by one.
    public var onHotKeyUp: ((UInt64) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let binding: Binding
    private let ready = DispatchSemaphore(value: 0)
    private var isDown = false

    public init(binding: Binding = .optionSpace) {
        self.binding = binding
    }

    public enum TapError: Error, CustomStringConvertible {
        case tapCreationFailed
        public var description: String {
            "CGEvent.tapCreate failed — Accessibility permission is required for event taps"
        }
    }

    /// Runs the tap on a thread of its own rather than the main run loop.
    ///
    /// Two reasons, both real. The system disables any tap whose callback
    /// runs long, so a tap sharing a thread with UI work is a tap that
    /// eventually goes deaf. And it frees callers to be plain async code
    /// instead of having to keep a run loop spinning to stay listening.
    public func start() throws {
        var thrown: Error?
        let t = Thread { [weak self] in
            guard let self else { return }
            do {
                try self.install()
            } catch {
                thrown = error
                self.ready.signal()
                return
            }
            self.runLoop = CFRunLoopGetCurrent()
            self.ready.signal()
            CFRunLoopRun()
        }
        t.name = "coach.hotkey.tap"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
        if let thrown { throw thrown }
    }

    private func install() throws {
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            me.handle(type: type, event: event)
            // Always pass the event through untouched — listen-only.
            return Unmanaged.passUnretained(event)
        }

        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: refcon
        ) else { throw TapError.tapCreationFailed }

        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop {
            if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFRunLoopStop(runLoop)
        }
        source = nil
        tap = nil
        runLoop = nil
        thread = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables a tap that ever runs long; re-arm rather than
        // going silently deaf.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .keyDown:
            guard binding.matches(keyCode: code, flags: event.flags) else { return }
            // Auto-repeat fires keyDown continuously while a key is held; a
            // push-to-talk turn must begin exactly once.
            guard !isDown else { return }
            isDown = true
            onHotKey?(Mono.machToNs(event.timestamp))

        case .keyUp:
            // Match on the key code alone, deliberately. Releasing Option
            // before Space changes the modifier flags, so requiring the full
            // combination here would drop the release and leave the
            // microphone running — the worst possible failure for this app.
            guard isDown, code == binding.keyCode else { return }
            isDown = false
            onHotKeyUp?(Mono.machToNs(event.timestamp))

        default:
            return
        }
    }

    deinit { stop() }
}
