import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenCoachCore

/// A single frame plus everything needed to map its pixels back to the screen.
///
/// The three fields travel together on purpose. Phase 0 found that capture
/// APIs disagree about framing and that an app's window can span several
/// `SCWindow`s, so a bare `CGImage` is not enough to say where anything is —
/// the origin, the scale and the display index have to accompany it or the
/// inverse mapping gets re-derived (wrongly) at the far end.
public struct Grab {
    public let image: CGImage
    /// Origin of this frame in global CG points.
    public let origin: CGPoint
    /// Pixels per point.
    public let scale: CGFloat
    public let screenIndex: Int
}

public enum ScreenGrab {

    /// Capture the display that mostly contains `rect`.
    ///
    /// Display-scoped rather than window-scoped, despite window scope being
    /// better for privacy, because Phase 0 measured the two capture paths
    /// framing the same window differently — and display space is the one
    /// frame where the AX→pixel mapping is a single subtraction and a single
    /// scale, verified pixel-exact on both Logic Pro and Chrome. The privacy
    /// gate is enforced separately, before this is ever called.
    ///
    /// Synchronous by design: this is called from the vision queue, where the
    /// caller is about to spend two seconds in a model anyway.
    public static func display(containing rect: ScreenRect) -> Grab? {
        let semaphore = DispatchSemaphore(value: 0)
        var grab: Grab?

        Task {
            defer { semaphore.signal() }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true) else { return }

            let space = DisplaySpace.current()
            let wanted = space.display(at: rect.screenIndex)
            // Match the SCDisplay to our display index by frame. Falling back
            // to `.first` would silently capture the wrong monitor on a
            // multi-display setup, which is the exact bug class this project
            // keeps guarding against.
            let display = content.displays.first { d in
                guard let wanted else { return false }
                return abs(d.frame.width - wanted.cgFrame.width) < 2
                    && abs(d.frame.height - wanted.cgFrame.height) < 2
                    && abs(d.frame.minX - wanted.cgFrame.minX) < 2
            } ?? content.displays.first
            guard let display else { return }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = WarmCapture.configuration(for: filter)
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config) else { return }

            grab = Grab(image: image,
                        origin: CGPoint(x: display.frame.minX, y: display.frame.minY),
                        scale: CGFloat(image.width) / CGFloat(display.width),
                        screenIndex: rect.screenIndex)
        }

        _ = semaphore.wait(timeout: .now() + 5)
        return grab
    }
}
