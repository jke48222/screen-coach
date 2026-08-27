import XCTest
@testable import ScreenCoachCore

final class AXResolverTests: XCTestCase {

    private let window = ScreenRect(cg: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                    screenIndex: 0)

    private func node(_ id: Int, role: String, title: String? = nil,
                      desc: String? = nil, help: String? = nil,
                      rect: CGRect = CGRect(x: 10, y: 10, width: 40, height: 30),
                      enabled: Bool = true) -> AXNode {
        AXNode(id: id, parentID: nil, depth: 1, role: role, title: title,
               roleDescription: desc, helpText: help, enabled: enabled,
               bounds: ScreenRect(cg: rect, screenIndex: 0))
    }

    private var tree: [AXNode] {
        [
            node(0, role: "AXGroup", title: "Transport",
                 rect: CGRect(x: 300, y: 60, width: 400, height: 60)),
            node(1, role: "AXButton", title: "Play",
                 help: "Play   ⌅, Play button. Start playback from the playhead.",
                 rect: CGRect(x: 340, y: 70, width: 40, height: 40)),
            node(2, role: "AXCheckBox", title: "Record",
                 help: "Record   R, Record button.",
                 rect: CGRect(x: 390, y: 70, width: 40, height: 40)),
            node(3, role: "AXStaticText", title: "Play",
                 rect: CGRect(x: 800, y: 400, width: 60, height: 20)),
            node(4, role: "AXButton", title: "Metronome Click",
                 rect: CGRect(x: 640, y: 70, width: 40, height: 40)),
            node(5, role: "AXWindow", title: "Untitled — Tracks",
                 rect: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            // The partial-tree case the fallback actually faces: a container
            // is labelled, its contents are not. Ablating the button below
            // leaves this group as the only thing sharing words with the
            // query — which is exactly what should aim the crop.
            node(6, role: "AXGroup", title: "Metronome and Tempo",
                 rect: CGRect(x: 600, y: 60, width: 140, height: 60)),
        ]
    }

    // MARK: - Ranking

    func testExactTitleWins() {
        let r = AXResolver.rank(query: "the Play button", in: tree, windowBounds: window)
        XCTAssertEqual(r.first?.node.id, 1)
        XCTAssertGreaterThan(r.first?.score ?? 0, AXResolver.hitThreshold)
    }

    /// "the Play button" must beat a static text that also reads "Play".
    /// Role agreement is the only thing separating them.
    func testRoleHintDisambiguatesIdenticalTitles() {
        let r = AXResolver.rank(query: "the Play button", in: tree, windowBounds: window)
        let play = r.first { $0.node.id == 1 }
        let label = r.first { $0.node.id == 3 }
        XCTAssertNotNil(play)
        if let label, let play {
            XCTAssertGreaterThan(play.score, label.score)
        }
    }

    /// The window element's title contains no query words, but a container
    /// spanning everything must never win on a partial match either.
    func testWholeWindowContainerIsPenalised() {
        let r = AXResolver.rank(query: "Untitled Tracks", in: tree, windowBounds: window)
        if let top = r.first, top.node.id == 5 {
            XCTAssertLessThan(top.score, AXResolver.hitThreshold,
                              "a window-sized match must not read as a confident hit")
        }
    }

    func testMultiWordTitleMatches() {
        let r = AXResolver.rank(query: "the Metronome Click button", in: tree,
                                windowBounds: window)
        XCTAssertEqual(r.first?.node.id, 4)
    }

    func testDisabledElementIsDemoted() {
        var t = tree
        t[1] = node(1, role: "AXButton", title: "Play",
                    rect: CGRect(x: 340, y: 70, width: 40, height: 40), enabled: false)
        let enabled = AXResolver.rank(query: "the Play button", in: tree, windowBounds: window)
        let disabled = AXResolver.rank(query: "the Play button", in: t, windowBounds: window)
        XCTAssertGreaterThan(enabled.first?.score ?? 0, disabled.first?.score ?? 0)
    }

    func testNoMatchReturnsNothing() {
        let r = AXResolver.rank(query: "quantum flux capacitor", in: tree, windowBounds: window)
        XCTAssertTrue(r.isEmpty || (r.first?.score ?? 0) < AXResolver.hitThreshold)
    }

    func testStopWordsDoNotCarrySignal() {
        let withStops = AXResolver.rank(query: "please click on the Play button",
                                        in: tree, windowBounds: window)
        let without = AXResolver.rank(query: "Play button", in: tree, windowBounds: window)
        XCTAssertEqual(withStops.first?.node.id, without.first?.node.id)
    }

    // MARK: - Crop aiming

    /// The point of Option 3: with the exact element hidden, the tree should
    /// still aim the crop at roughly the right place via a neighbour or the
    /// containing group — not fall back to the whole window.
    func testCropHintNarrowsEvenWhenTargetIsMissing() {
        let hint = AXResolver.cropHint(query: "the Metronome Click button", in: tree,
                                       windowBounds: window, excluding: [4])
        XCTAssertFalse(hint.isWholeWindow, "should still narrow using surviving nodes")
        let area = hint.rect.cg.width * hint.rect.cg.height
        let windowArea = window.cg.width * window.cg.height
        XCTAssertLessThan(area / windowArea, 0.5)
    }

    /// The ambiguity case. With the real Play button hidden, a distant static
    /// text also reading "Play" is the top match — betting the crop on it
    /// alone would aim at the wrong half of the window. Covering near-ties
    /// keeps the true target inside the crop.
    func testCropHintContainsTheHiddenTargetDespiteAnAmbiguousLabel() {
        let target = tree[1].bounds.cg
        let hint = AXResolver.cropHint(query: "the Play button", in: tree,
                                       windowBounds: window, excluding: [1])
        XCTAssertTrue(hint.rect.cg.intersects(target),
                      "an aimed crop that excludes the target is worse than useless")
    }

    /// …but hedging must not become "crop everything". An unambiguous match
    /// should still produce a tight crop, or the latency win evaporates.
    func testUnambiguousMatchStillCropsTightly() {
        let hint = AXResolver.cropHint(query: "the Record button", in: tree,
                                       windowBounds: window)
        let area = hint.rect.cg.width * hint.rect.cg.height
        XCTAssertLessThan(area / (window.cg.width * window.cg.height), 0.15)
    }

    func testCropHintFallsBackToWholeWindowWhenTreeKnowsNothing() {
        let hint = AXResolver.cropHint(query: "quantum flux capacitor", in: tree,
                                       windowBounds: window)
        XCTAssertTrue(hint.isWholeWindow)
        XCTAssertEqual(hint.confidence, 0)
    }

    func testCropHintNeverEscapesTheWindow() {
        let edge = [node(9, role: "AXButton", title: "Corner",
                         rect: CGRect(x: 0, y: 0, width: 20, height: 20))]
        let hint = AXResolver.cropHint(query: "the Corner button", in: edge,
                                       windowBounds: window)
        XCTAssertTrue(window.cg.contains(hint.rect.cg))
    }

    func testCropHintCarriesScreenIndex() {
        let onSecond = ScreenRect(cg: CGRect(x: -1000, y: -800, width: 1000, height: 800),
                                  screenIndex: 1)
        let nodes = [AXNode(id: 0, parentID: nil, depth: 1, role: "AXButton",
                            title: "Play",
                            bounds: ScreenRect(cg: CGRect(x: -600, y: -400, width: 40, height: 30),
                                               screenIndex: 1))]
        let hint = AXResolver.cropHint(query: "the Play button", in: nodes,
                                       windowBounds: onSecond)
        XCTAssertEqual(hint.rect.screenIndex, 1,
                       "the screen index must survive crop aiming or the pointer lands on the wrong monitor")
    }
}
