import AppKit
import ScreenCoachCore

public extension DisplaySpace {

    /// Build the display layout from AppKit, flipping every screen into CG
    /// space once, here, so nothing downstream has to remember which way is
    /// up. `NSScreen.screens[0]` is the primary display — the anchor both
    /// coordinate spaces share — and is deliberately not `NSScreen.main`,
    /// which merely follows focus.
    static func current() -> DisplaySpace {
        let screens = NSScreen.screens
        guard let primary = screens.first else {
            return DisplaySpace(displays: [])
        }
        let h = primary.frame.height
        let infos = screens.enumerated().map { index, screen -> DisplayInfo in
            let ak = screen.frame
            return DisplayInfo(
                index: index,
                cgFrame: CGRect(x: ak.origin.x, y: h - ak.origin.y - ak.height,
                                width: ak.width, height: ak.height),
                scale: screen.backingScaleFactor
            )
        }
        return DisplaySpace(displays: infos)
    }

    var describeLayout: String {
        displays.map { d in
            String(format: "  screen %d%@ cg=(%.0f,%.0f %.0f×%.0f) @%.0fx",
                   d.index, d.isPrimary ? " [primary]" : "",
                   d.cgFrame.minX, d.cgFrame.minY,
                   d.cgFrame.width, d.cgFrame.height, d.scale)
        }.joined(separator: "\n")
    }
}
