import XCTest
@testable import ScreenCoachCore

/// The multi-display coordinate trap, tested against a synthetic layout so it
/// is covered without owning three monitors. This is the bug the brief says
/// every builder in this space hits first, so it gets tests before it gets a
/// pointer to render.
final class DisplaySpaceTests: XCTestCase {

    /// A laptop (primary, 1728×1117 @2x) with a 4K display placed ABOVE and
    /// to the LEFT of it. Above-left is the layout that breaks naive code:
    /// the secondary display sits at negative coordinates in both spaces.
    private var space: DisplaySpace {
        DisplaySpace(displays: [
            DisplayInfo(index: 0, cgFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117), scale: 2),
            DisplayInfo(index: 1, cgFrame: CGRect(x: -3008, y: -1692, width: 3008, height: 1692), scale: 2),
        ])
    }

    func testPrimaryHeightIsPrimaryNotMain() {
        XCTAssertEqual(space.primaryHeight, 1117)
    }

    func testFlipRoundTripsOnPrimary() {
        let cg = CGRect(x: 100, y: 50, width: 200, height: 80)
        let ak = space.appKitRect(fromCG: cg)
        XCTAssertEqual(ak.origin.y, 1117 - 50 - 80)
        XCTAssertEqual(space.cgRect(fromAppKit: ak), cg)
    }

    /// The case that catches sign errors: a rect on a display at negative
    /// coordinates still has to survive the round trip.
    func testFlipRoundTripsOnNegativeSecondaryDisplay() {
        let cg = CGRect(x: -2000, y: -1500, width: 400, height: 300)
        let ak = space.appKitRect(fromCG: cg)
        XCTAssertEqual(space.cgRect(fromAppKit: ak), cg)
    }

    func testPointRoundTrip() {
        let p = CGPoint(x: -1200, y: -900)
        XCTAssertEqual(space.cgPoint(fromAppKit: space.appKitPoint(fromCG: p)), p)
    }

    func testIndexContainingPoint() {
        XCTAssertEqual(space.index(containing: CGPoint(x: 10, y: 10)), 0)
        XCTAssertEqual(space.index(containing: CGPoint(x: -100, y: -100)), 1)
        XCTAssertNil(space.index(containing: CGPoint(x: 9999, y: 9999)))
    }

    /// A window straddling two displays belongs to whichever shows more of it.
    func testStraddlingWindowGoesToMajorityDisplay() {
        let mostlySecondary = CGRect(x: -300, y: -100, width: 400, height: 100)
        XCTAssertEqual(space.index(bestOverlapping: mostlySecondary), 1)

        let mostlyPrimary = CGRect(x: -100, y: 10, width: 400, height: 100)
        XCTAssertEqual(space.index(bestOverlapping: mostlyPrimary), 0)
    }

    /// A collapsed element still has to be pointable rather than nil.
    func testZeroSizeRectStillAttributed() {
        let collapsed = CGRect(x: -500, y: -500, width: 0, height: 0)
        XCTAssertEqual(space.index(bestOverlapping: collapsed), 1)
    }

    func testAttributeFallsBackToPrimaryWhenOffscreen() {
        let off = space.attribute(CGRect(x: 99999, y: 99999, width: 10, height: 10))
        XCTAssertEqual(off.screenIndex, 0)
    }

    // MARK: - Vision fallback round trip

    /// A grounding model sees a crop and answers in crop pixels. That answer
    /// has to land back on the right monitor, at the right point, through a
    /// Retina scale factor. This is the whole vision-fallback coordinate path
    /// in one test.
    func testCropPixelRoundTripsToGlobalPoint() {
        let s = space
        // An element at CG (-2000, -1500) on the secondary display.
        let element = ScreenPoint(cg: CGPoint(x: -2000, y: -1500), screenIndex: 1)

        // Where it sits in that display's pixels: (1008, 192) × scale 2.
        let pixel = s.pixelInDisplay(element)
        XCTAssertEqual(pixel?.x ?? 0, (-2000 - -3008) * 2, accuracy: 0.001)
        XCTAssertEqual(pixel?.y ?? 0, (-1500 - -1692) * 2, accuracy: 0.001)

        // Crop the window starting 500×100 display-pixels in; the model
        // reports the element relative to the crop.
        let cropOrigin = CGPoint(x: 500, y: 100)
        let inCrop = CGPoint(x: pixel!.x - cropOrigin.x, y: pixel!.y - cropOrigin.y)

        let back = s.screenPoint(fromCropPixel: inCrop,
                                 cropOriginInDisplayPixels: cropOrigin,
                                 screenIndex: 1)
        XCTAssertEqual(back?.cg.x ?? 0, element.cg.x, accuracy: 0.001)
        XCTAssertEqual(back?.cg.y ?? 0, element.cg.y, accuracy: 0.001)
        XCTAssertEqual(back?.screenIndex, 1)
    }

    /// Scale must not be assumed uniform: a Retina laptop next to a 1x
    /// external is the common real setup, and a shared scale factor would
    /// put the pointer at half or double the offset on one of them.
    func testMixedScaleFactorsAreHonoured() {
        let mixed = DisplaySpace(displays: [
            DisplayInfo(index: 0, cgFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117), scale: 2),
            DisplayInfo(index: 1, cgFrame: CGRect(x: 1728, y: 0, width: 1920, height: 1080), scale: 1),
        ])
        let onExternal = ScreenPoint(cg: CGPoint(x: 1728 + 200, y: 300), screenIndex: 1)
        XCTAssertEqual(mixed.pixelInDisplay(onExternal)?.x ?? 0, 200, accuracy: 0.001)

        let onLaptop = ScreenPoint(cg: CGPoint(x: 200, y: 300), screenIndex: 0)
        XCTAssertEqual(mixed.pixelInDisplay(onLaptop)?.x ?? 0, 400, accuracy: 0.001)
    }

    func testUnknownScreenIndexIsRejectedNotGuessed() {
        XCTAssertNil(space.pixelInDisplay(ScreenPoint(cg: .zero, screenIndex: 7)))
        XCTAssertNil(space.screenPoint(fromCropPixel: .zero,
                                       cropOriginInDisplayPixels: .zero,
                                       screenIndex: 7))
    }
}
