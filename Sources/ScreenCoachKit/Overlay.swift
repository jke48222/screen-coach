import AppKit
import QuartzCore
import ScreenCoachCore

/// The pet's window recipe from WindowPet, reused verbatim because it is the
/// same problem: draw over everything, on every Space, and never take a click
/// or a keystroke away from the app the user is actually working in.
public final class OverlayPanel: NSPanel {

    public init(screenFrame: CGRect) {
        super.init(contentRect: screenFrame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Above fullscreen content — a coach that vanishes when you go
        // fullscreen is useless for teaching video editors and DAWs.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = {
            let v = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
            v.wantsLayer = true
            v.layer?.masksToBounds = false
            return v
        }()
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

/// Draws the pointer and its annotations.
///
/// The bezier arc is not decoration. A dot that teleports has to be *found*;
/// a cursor that flies along a curve is tracked by the eye the whole way, so
/// the user arrives at the target already looking at it. That is the one
/// interaction insight Clicky got right and it is worth copying exactly.
///
/// Confidence is rendered, not hidden. A solid ring means the accessibility
/// tree resolved the element exactly; a dashed ring means the match was
/// uncertain or two candidates disagreed. A teacher that admits doubt gets
/// trusted; one that is confidently wrong gets uninstalled.
public final class PointerLayer {

    public enum Confidence {
        /// Resolved on the AX tree above threshold — exact bounds.
        case exact
        /// Matched, but below threshold, or vision and AX disagreed.
        case uncertain
    }

    public let root = CALayer()
    private let cursor = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let label = CATextLayer()
    private let labelBG = CALayer()
    private let scrim = CAShapeLayer()
    private let badge = CAShapeLayer()
    private let badgeText = CATextLayer()

    private static let accent = NSColor(srgbRed: 0.20, green: 0.55, blue: 1.0, alpha: 1)
    private static let warn = NSColor(srgbRed: 1.0, green: 0.70, blue: 0.10, alpha: 1)

    public init() {
        root.actions = noImplicitAnimations
        root.isHidden = true

        // A cursor-shaped arrow rather than a dot: it has an obvious "tip",
        // so there is never ambiguity about which pixel is being indicated.
        cursor.path = Self.arrowPath()
        cursor.fillColor = Self.accent.cgColor
        cursor.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        cursor.lineWidth = 1.5
        cursor.lineJoin = .round
        cursor.shadowColor = NSColor.black.cgColor
        cursor.shadowOpacity = 0.35
        cursor.shadowRadius = 6
        cursor.shadowOffset = CGSize(width: 0, height: -2)
        cursor.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        cursor.anchorPoint = CGPoint(x: 0.12, y: 0.9)   // the arrow's tip
        cursor.actions = noImplicitAnimations

        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = Self.accent.cgColor
        ring.lineWidth = 3
        ring.actions = noImplicitAnimations

        labelBG.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        labelBG.cornerRadius = 7
        labelBG.actions = noImplicitAnimations
        label.fontSize = 13
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        label.truncationMode = .end
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        label.actions = noImplicitAnimations

        // Scrim first so everything else draws on top of it.
        scrim.fillColor = NSColor.black.withAlphaComponent(0.42).cgColor
        // Even-odd is what punches the hole: the outer rect and the target
        // rect are both in one path, and the overlap cancels.
        scrim.fillRule = .evenOdd
        scrim.actions = noImplicitAnimations
        scrim.isHidden = true

        badge.fillColor = Self.accent.cgColor
        badge.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        badge.lineWidth = 2
        badge.actions = noImplicitAnimations
        badge.isHidden = true
        badgeText.fontSize = 15
        badgeText.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        badgeText.foregroundColor = NSColor.white.cgColor
        badgeText.alignmentMode = .center
        badgeText.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        badgeText.actions = noImplicitAnimations
        badgeText.isHidden = true

        root.addSublayer(scrim)
        root.addSublayer(ring)
        root.addSublayer(badge)
        root.addSublayer(badgeText)
        root.addSublayer(labelBG)
        root.addSublayer(label)
        root.addSublayer(cursor)
    }

    private var noImplicitAnimations: [String: CAAction] {
        ["position": NSNull(), "bounds": NSNull(), "path": NSNull(),
         "hidden": NSNull(), "opacity": NSNull(), "transform": NSNull(),
         "contents": NSNull(), "backgroundColor": NSNull()]
    }

    // MARK: - Presentation

    /// Dim everything except the target.
    ///
    /// The single most effective "look here" affordance there is, and the one
    /// that turns a pointer into a teacher: during a step the rest of the
    /// screen recedes and the control you need is the only lit thing. Used
    /// only for lessons, never for a one-shot answer — dimming someone's whole
    /// screen to answer a quick question is obnoxious.
    public func setScrim(cutout: CGRect?, stepNumber: Int?) {
        guard let cutout else {
            scrim.isHidden = true
            badge.isHidden = true
            badgeText.isHidden = true
            return
        }
        let path = CGMutablePath()
        path.addRect(root.bounds)
        path.addRoundedRect(in: cutout.insetBy(dx: -10, dy: -10),
                            cornerWidth: 10, cornerHeight: 10)
        scrim.path = path
        scrim.frame = root.bounds
        scrim.isHidden = false

        guard let stepNumber else {
            badge.isHidden = true
            badgeText.isHidden = true
            return
        }
        // Badge sits at the target's top-left, nudged outside so it never
        // covers the thing it is pointing at.
        let d: CGFloat = 30
        let origin = CGPoint(x: cutout.minX - d - 6, y: cutout.maxY - d / 2)
        let box = CGRect(x: origin.x, y: origin.y, width: d, height: d)
        badge.path = CGPath(ellipseIn: box, transform: nil)
        badge.isHidden = false
        badgeText.string = "\(stepNumber)"
        badgeText.frame = CGRect(x: box.minX, y: box.minY + 5, width: d, height: d - 8)
        badgeText.isHidden = false
    }

    /// Fly to `target` and mark it. Coordinates are in the panel's own
    /// (AppKit, bottom-left origin) space; the caller has already chosen the
    /// right panel using the target's screen index, which is what keeps the
    /// pointer off the wrong monitor.
    public func point(from start: CGPoint, to target: CGPoint, box: CGRect,
                      caption: String, confidence: Confidence,
                      duration: CFTimeInterval = 0.55) {
        let tint = confidence == .exact ? Self.accent : Self.warn
        cursor.fillColor = tint.cgColor
        ring.strokeColor = tint.cgColor
        ring.lineDashPattern = confidence == .exact ? nil : [6, 5]

        // Ring hugs the element's real bounds, padded a little so it reads as
        // "this control" rather than "this rectangle".
        let ringRect = box.insetBy(dx: -7, dy: -7)
        ring.path = CGPath(roundedRect: ringRect, cornerWidth: 8, cornerHeight: 8,
                           transform: nil)

        layoutLabel(caption, near: ringRect, tint: tint)

        root.isHidden = false
        root.opacity = 1

        // Arc, not a straight line: the control point is pushed perpendicular
        // to the travel direction so the path bows. Longer trips bow more,
        // which is what makes the motion legible rather than merely animated.
        let path = CGMutablePath()
        path.move(to: start)
        let dx = target.x - start.x, dy = target.y - start.y
        let dist = max(1, (dx * dx + dy * dy).squareRoot())
        let bow = min(dist * 0.28, 220)
        let mid = CGPoint(x: (start.x + target.x) / 2, y: (start.y + target.y) / 2)
        let control = CGPoint(x: mid.x + (-dy / dist) * bow,
                              y: mid.y + (dx / dist) * bow)
        path.addQuadCurve(to: target, control: control)

        let fly = CAKeyframeAnimation(keyPath: "position")
        fly.path = path
        fly.duration = duration
        fly.calculationMode = .paced
        // Ease out hard: fast departure, settled arrival. A linear flight
        // reads as mechanical and overshoots the eye.
        fly.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.9, 0.2, 1)
        fly.fillMode = .forwards
        fly.isRemovedOnCompletion = false
        cursor.position = target
        cursor.add(fly, forKey: "fly")

        // The ring and caption arrive with the cursor, not before it —
        // otherwise the answer is visible while the pointer is still in
        // flight and the flight becomes pointless.
        for l in [ring, labelBG, label] {
            l.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.beginTime = CACurrentMediaTime() + duration * 0.72
            fade.duration = 0.18
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            l.add(fade, forKey: "fade")
            l.opacity = 1
        }

        pulse(ringRect)
    }

    /// A single expanding echo on arrival. One, not a loop: a permanently
    /// pulsing ring becomes wallpaper within a minute.
    private func pulse(_ rect: CGRect) {
        let echo = CAShapeLayer()
        echo.path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        echo.fillColor = NSColor.clear.cgColor
        echo.strokeColor = ring.strokeColor
        echo.lineWidth = 2.5
        echo.opacity = 0
        echo.frame = root.bounds
        root.insertSublayer(echo, below: cursor)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1.0
        grow.toValue = 1.35
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.7
        group.beginTime = CACurrentMediaTime() + 0.38
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        echo.add(group, forKey: "echo")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { echo.removeFromSuperlayer() }
    }

    private func layoutLabel(_ text: String, near rect: CGRect, tint: NSColor) {
        label.string = text
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let width = min(360, (text as NSString)
            .size(withAttributes: [.font: font]).width + 22)
        let height: CGFloat = 24
        // Prefer above the target; flip below when there is no room, so the
        // caption never runs off the top of the screen.
        var y = rect.maxY + 10
        if y + height > root.bounds.maxY - 6 { y = rect.minY - height - 10 }
        let x = min(max(rect.midX - width / 2, 6), root.bounds.maxX - width - 6)
        labelBG.frame = CGRect(x: x, y: y, width: width, height: height)
        labelBG.borderColor = tint.withAlphaComponent(0.5).cgColor
        labelBG.borderWidth = 1
        label.frame = CGRect(x: x, y: y + 4, width: width, height: height - 7)
    }

    public func hide() {
        root.isHidden = true
        scrim.isHidden = true
        badge.isHidden = true
        badgeText.isHidden = true
        cursor.removeAllAnimations()
        for l in [ring, labelBG, label] { l.removeAllAnimations() }
    }

    public func resize(to size: CGSize) {
        root.frame = CGRect(origin: .zero, size: size)
        ring.frame = root.frame
        scrim.frame = root.frame
    }

    private static func arrowPath() -> CGPath {
        // A classic pointer: tip at top-left, tail notched.
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 3, y: 25))
        p.addLine(to: CGPoint(x: 3, y: 3))
        p.addLine(to: CGPoint(x: 18, y: 13))
        p.addLine(to: CGPoint(x: 10.5, y: 13.5))
        p.addLine(to: CGPoint(x: 15, y: 22))
        p.addLine(to: CGPoint(x: 11, y: 24))
        p.addLine(to: CGPoint(x: 7, y: 15.5))
        p.closeSubpath()
        return p
    }
}

/// Owns one overlay panel per display and routes a target to the right one.
///
/// The routing is the whole reason `ScreenPoint` carries an explicit screen
/// index. Picking a panel by "which screen contains this point" recomputed
/// downstream is how the pointer ends up on the wrong monitor — the index
/// travels with the coordinate from the AX bounds all the way to here.
public final class OverlayController {

    private var panels: [Int: OverlayPanel] = [:]
    private var pointers: [Int: PointerLayer] = [:]
    private var space = DisplaySpace.current()
    private var hideWorkItem: DispatchWorkItem?

    public init() {}

    public func rebuildForCurrentDisplays() {
        for (_, panel) in panels { panel.orderOut(nil) }
        panels.removeAll()
        pointers.removeAll()
        space = DisplaySpace.current()

        for (index, screen) in NSScreen.screens.enumerated() {
            let panel = OverlayPanel(screenFrame: screen.frame)
            let pointer = PointerLayer()
            pointer.resize(to: screen.frame.size)
            panel.contentView?.layer?.addSublayer(pointer.root)
            panels[index] = panel
            pointers[index] = pointer
        }
    }

    /// Point at an element. `bounds` is in CG space with its screen index
    /// attached; everything below converts once, here.
    public func point(at bounds: ScreenRect, caption: String,
                      confidence: PointerLayer.Confidence,
                      dismissAfter: TimeInterval = 4.5) {
        if panels.isEmpty { rebuildForCurrentDisplays() }
        guard let panel = panels[bounds.screenIndex],
              let pointer = pointers[bounds.screenIndex],
              let screen = NSScreen.screens[safe: bounds.screenIndex] else { return }

        // CG (top-left origin, global) → AppKit (bottom-left origin, global)
        // → panel-local. Two steps, both explicit.
        let ak = space.appKitRect(fromCG: bounds.cg)
        let local = CGRect(x: ak.minX - screen.frame.minX,
                           y: ak.minY - screen.frame.minY,
                           width: ak.width, height: ak.height)

        // Start the flight from the mouse, since that is where the user's
        // attention already is.
        let mouse = NSEvent.mouseLocation
        let start = CGPoint(x: mouse.x - screen.frame.minX,
                            y: mouse.y - screen.frame.minY)

        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        pointer.resize(to: screen.frame.size)
        // A one-shot answer never dims the screen, and must clear a scrim a
        // previous lesson left behind.
        pointer.setScrim(cutout: nil, stepNumber: nil)
        pointer.point(from: start, to: CGPoint(x: local.midX, y: local.midY),
                      box: local, caption: caption, confidence: confidence)

        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissAfter, execute: work)
    }

    /// Teaching mode: point, dim everything else, and number the step.
    ///
    /// Unlike `point`, this does not auto-dismiss. A step stays lit until the
    /// learner completes it — the whole premise is that the coach waits for
    /// the person rather than the person keeping up with the coach.
    public func teach(step bounds: ScreenRect, caption: String, stepNumber: Int,
                      confidence: PointerLayer.Confidence) {
        if panels.isEmpty { rebuildForCurrentDisplays() }
        guard let panel = panels[bounds.screenIndex],
              let pointer = pointers[bounds.screenIndex],
              let screen = NSScreen.screens[safe: bounds.screenIndex] else { return }

        let ak = space.appKitRect(fromCG: bounds.cg)
        let local = CGRect(x: ak.minX - screen.frame.minX,
                           y: ak.minY - screen.frame.minY,
                           width: ak.width, height: ak.height)
        let mouse = NSEvent.mouseLocation
        let start = CGPoint(x: mouse.x - screen.frame.minX,
                            y: mouse.y - screen.frame.minY)

        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        pointer.resize(to: screen.frame.size)
        pointer.setScrim(cutout: local, stepNumber: stepNumber)
        pointer.point(from: start, to: CGPoint(x: local.midX, y: local.midY),
                      box: local, caption: caption, confidence: confidence)
    }

    public func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        for (_, p) in pointers { p.hide() }
        for (_, panel) in panels { panel.orderOut(nil) }
    }
}

public extension Array {
    /// Bounds-checked access. Screen indices arrive from AX bounds and can
    /// outlive the display they referred to — someone unplugs a monitor
    /// between extraction and pointing — so every lookup by index is guarded.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
