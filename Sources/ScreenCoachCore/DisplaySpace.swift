import CoreGraphics

/// THE trap this project exists to not fall into.
///
/// Two global coordinate spaces span every display, and they disagree:
///
///  * **CG space** — what `CGWindowListCopyWindowInfo` bounds and the AX
///    `kAXPositionAttribute` both return. Origin at the TOP-LEFT of the
///    PRIMARY display, Y increasing DOWNWARD.
///  * **AppKit space** — what `NSScreen.frame` and `NSWindow.frame` use.
///    Origin at the BOTTOM-LEFT of the PRIMARY display, Y increasing UPWARD.
///
/// Both are anchored to the *primary* display (`NSScreen.screens[0]`), NOT
/// `NSScreen.main` — main is merely the screen with focus and moves around.
/// Because both spaces share that anchor, a single flip against the primary
/// screen's height converts correctly on every display, including secondary
/// displays sitting at negative coordinates.
///
/// Getting this wrong points the cursor at the wrong monitor, which is the
/// first bug everyone building in this space hits. The defence here is
/// `ScreenPoint`: a coordinate that refuses to exist without the index of the
/// display it belongs to, carried explicitly all the way from AX bounds to
/// the overlay — the same discipline as Clicky's `screenN` POINT tag.
public struct DisplayInfo: Equatable, Sendable {
    /// Index into `NSScreen.screens`. 0 is always the primary display.
    public let index: Int
    /// Frame in CG space (top-left origin).
    public let cgFrame: CGRect
    /// Backing scale — 2.0 on Retina. Vision grounding runs in pixels,
    /// AX and the overlay run in points; this is the conversion factor.
    public let scale: CGFloat

    public init(index: Int, cgFrame: CGRect, scale: CGFloat) {
        self.index = index
        self.cgFrame = cgFrame
        self.scale = scale
    }

    public var isPrimary: Bool { index == 0 }
}

/// A point that knows which display it is on. Constructing one without an
/// index is impossible on purpose.
public struct ScreenPoint: Equatable, Sendable {
    /// CG space (top-left origin, spans all displays).
    public let cg: CGPoint
    public let screenIndex: Int

    public init(cg: CGPoint, screenIndex: Int) {
        self.cg = cg
        self.screenIndex = screenIndex
    }
}

/// A rect that knows which display it is on.
public struct ScreenRect: Equatable, Sendable {
    public let cg: CGRect
    public let screenIndex: Int

    public init(cg: CGRect, screenIndex: Int) {
        self.cg = cg
        self.screenIndex = screenIndex
    }

    public var center: ScreenPoint {
        ScreenPoint(cg: CGPoint(x: cg.midX, y: cg.midY), screenIndex: screenIndex)
    }
}

/// The display layout, as a pure value so multi-display logic can be tested
/// without owning multi-display hardware.
public struct DisplaySpace: Equatable, Sendable {
    public let displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) {
        self.displays = displays.sorted { $0.index < $1.index }
    }

    public var primary: DisplayInfo? { displays.first { $0.isPrimary } }

    /// Height of the primary display — the single number every flip needs.
    public var primaryHeight: CGFloat { primary?.cgFrame.height ?? 0 }

    public func display(at index: Int) -> DisplayInfo? {
        displays.first { $0.index == index }
    }

    // MARK: - Space conversion

    /// CG rect (top-left origin) → AppKit rect (bottom-left origin).
    public func appKitRect(fromCG r: CGRect) -> CGRect {
        CGRect(x: r.origin.x,
               y: primaryHeight - r.origin.y - r.height,
               width: r.width, height: r.height)
    }

    /// AppKit rect → CG rect. Exact inverse of `appKitRect(fromCG:)`.
    public func cgRect(fromAppKit r: CGRect) -> CGRect {
        CGRect(x: r.origin.x,
               y: primaryHeight - r.origin.y - r.height,
               width: r.width, height: r.height)
    }

    /// CG point → AppKit point.
    public func appKitPoint(fromCG p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// AppKit point → CG point.
    public func cgPoint(fromAppKit p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    // MARK: - Attribution

    /// Which display contains this CG point. Nil only if it is in the gap
    /// between displays or off every screen.
    public func index(containing p: CGPoint) -> Int? {
        displays.first { $0.cgFrame.contains(p) }?.index
    }

    /// Which display a rect mostly lives on, by intersection area. A window
    /// straddling two monitors belongs to the one showing more of it; ties
    /// go to the lower index, which keeps the answer stable frame to frame.
    public func index(bestOverlapping r: CGRect) -> Int? {
        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for d in displays {
            let i = d.cgFrame.intersection(r)
            guard !i.isNull else { continue }
            let area = i.width * i.height
            if area > bestArea {
                bestArea = area
                bestIndex = d.index
            }
        }
        // Zero-area rects (a collapsed element) still deserve an answer:
        // fall back to whichever display holds their origin.
        if bestIndex == nil { return index(containing: r.origin) }
        return bestIndex
    }

    /// Attach a display index to a raw CG rect. Falls back to the primary
    /// display rather than returning nil — an unplaceable element still needs
    /// to be pointable, and index 0 is the one display guaranteed to exist.
    public func attribute(_ r: CGRect) -> ScreenRect {
        ScreenRect(cg: r, screenIndex: index(bestOverlapping: r) ?? 0)
    }

    public func attribute(_ p: CGPoint) -> ScreenPoint {
        ScreenPoint(cg: p, screenIndex: index(containing: p) ?? 0)
    }

    // MARK: - Vision-fallback support

    /// CG point → pixel coordinates within its own display, which is the
    /// space a cropped screenshot fed to a grounding model lives in. Returns
    /// nil if the point's declared screen does not exist.
    public func pixelInDisplay(_ p: ScreenPoint) -> CGPoint? {
        guard let d = display(at: p.screenIndex) else { return nil }
        return CGPoint(x: (p.cg.x - d.cgFrame.minX) * d.scale,
                       y: (p.cg.y - d.cgFrame.minY) * d.scale)
    }

    /// The inverse: a grounding model returns a pixel inside a crop, and this
    /// puts it back into global CG space with its display index intact.
    /// `cropOriginInDisplayPixels` is where the crop was taken from.
    public func screenPoint(fromCropPixel pixel: CGPoint,
                            cropOriginInDisplayPixels origin: CGPoint,
                            screenIndex: Int) -> ScreenPoint? {
        guard let d = display(at: screenIndex) else { return nil }
        let displayPixel = CGPoint(x: origin.x + pixel.x, y: origin.y + pixel.y)
        return ScreenPoint(
            cg: CGPoint(x: d.cgFrame.minX + displayPixel.x / d.scale,
                        y: d.cgFrame.minY + displayPixel.y / d.scale),
            screenIndex: screenIndex
        )
    }
}
