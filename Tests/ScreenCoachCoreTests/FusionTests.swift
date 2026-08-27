import XCTest
@testable import ScreenCoachCore

/// The fusion rules are the project's actual claim, so they are tested as a
/// policy rather than as plumbing: every combination of "tree answered / vision
/// answered / they agree" has a defined, defensible outcome.
final class FusionTests: XCTestCase {

    private let threshold = AXResolver.hitThreshold

    private func ax(_ rect: CGRect, score: Double, screen: Int = 0) -> Fusion.AXCandidate {
        Fusion.AXCandidate(bounds: ScreenRect(cg: rect, screenIndex: screen),
                           score: score, label: "Play")
    }

    private func vision(_ p: CGPoint, screen: Int = 0) -> Fusion.VisionCandidate {
        Fusion.VisionCandidate(point: ScreenPoint(cg: p, screenIndex: screen))
    }

    private let button = CGRect(x: 100, y: 100, width: 60, height: 40)

    // MARK: - Single-source

    func testStrongAXAloneIsExact() {
        let d = Fusion.decide(ax: ax(button, score: 0.95), vision: nil,
                              axHitThreshold: threshold)
        XCTAssertEqual(d?.confidence, .exact)
        XCTAssertEqual(d?.source, .accessibility)
        XCTAssertNil(d?.explanation)
    }

    func testWeakAXAloneIsUncertainAndSaysWhy() {
        let d = Fusion.decide(ax: ax(button, score: 0.40), vision: nil,
                              axHitThreshold: threshold)
        XCTAssertEqual(d?.confidence, .uncertain)
        XCTAssertNotNil(d?.explanation)
    }

    /// The central honesty rule. A vision-only answer is never solid, because
    /// nothing corroborates it and its base rate on dense UIs is 58%.
    func testVisionAloneIsNeverConfident() {
        let d = Fusion.decide(ax: nil, vision: vision(CGPoint(x: 500, y: 500)),
                              axHitThreshold: threshold)
        XCTAssertEqual(d?.confidence, .uncertain)
        XCTAssertEqual(d?.source, .vision)
        XCTAssertNotNil(d?.explanation)
    }

    /// A point has no extent; the ring must not imply pixel precision the
    /// method does not have.
    func testVisionOnlyRingHasHonestSize() {
        let d = Fusion.decide(ax: nil, vision: vision(CGPoint(x: 500, y: 400)),
                              axHitThreshold: threshold)
        XCTAssertEqual(d?.target.cg.width, Fusion.visionRingSize)
        XCTAssertEqual(d?.target.cg.midX ?? 0, 500, accuracy: 0.001)
        XCTAssertEqual(d?.target.cg.midY ?? 0, 400, accuracy: 0.001)
    }

    func testNothingFoundReturnsNoDecision() {
        XCTAssertNil(Fusion.decide(ax: nil, vision: nil, axHitThreshold: threshold))
    }

    // MARK: - Corroboration

    func testAgreementEarnsConfidence() {
        let d = Fusion.decide(ax: ax(button, score: 0.70),
                              vision: vision(CGPoint(x: 130, y: 120)),
                              axHitThreshold: threshold)
        XCTAssertEqual(d?.source, .corroborated)
        XCTAssertEqual(d?.confidence, .exact)
    }

    /// Corroboration is stronger than either path alone: a *weak* AX match
    /// that vision independently lands inside is more trustworthy than a
    /// strong AX match nothing checked.
    func testAgreementPromotesAWeakAXMatch() {
        let weak = Fusion.decide(ax: ax(button, score: 0.30), vision: nil,
                                 axHitThreshold: threshold)
        XCTAssertEqual(weak?.confidence, .uncertain)

        let corroborated = Fusion.decide(ax: ax(button, score: 0.30),
                                         vision: vision(CGPoint(x: 130, y: 120)),
                                         axHitThreshold: threshold)
        XCTAssertEqual(corroborated?.confidence, .exact)
        XCTAssertEqual(corroborated?.source, .corroborated)
    }

    func testSlackAllowsAPointJustOutsideTightBounds() {
        // 4 pt outside — inside the slack, still the same control.
        let d = Fusion.decide(ax: ax(button, score: 0.80),
                              vision: vision(CGPoint(x: 164, y: 120)),
                              axHitThreshold: threshold)
        XCTAssertEqual(d?.source, .corroborated)
    }

    // MARK: - Conflict

    func testDisagreementIsReportedNotHidden() {
        let d = Fusion.decide(ax: ax(button, score: 0.95),
                              vision: vision(CGPoint(x: 900, y: 700)),
                              axHitThreshold: threshold)
        XCTAssertEqual(d?.source, .conflicted)
        XCTAssertEqual(d?.confidence, .uncertain,
                       "a strong AX match must still go dashed when vision contradicts it")
        XCTAssertNotNil(d?.explanation)
    }

    /// On conflict the tree's geometry wins the *pointer*, because when the
    /// element exists its bounds are exact — but it does not win the ring.
    func testConflictStillPointsAtTheTreesAnswer() {
        let d = Fusion.decide(ax: ax(button, score: 0.95),
                              vision: vision(CGPoint(x: 900, y: 700)),
                              axHitThreshold: threshold)
        XCTAssertEqual(d?.target.cg, button)
    }

    /// The multi-display trap again: same coordinates on different monitors is
    /// not agreement, it is the worst kind of disagreement.
    func testSameCoordinatesOnDifferentScreensIsNotAgreement() {
        let d = Fusion.decide(ax: ax(button, score: 0.9, screen: 0),
                              vision: vision(CGPoint(x: 130, y: 120), screen: 1),
                              axHitThreshold: threshold)
        XCTAssertEqual(d?.source, .conflicted)
    }

    func testDistanceIsToTheEdgeNotTheCentre() {
        // 40 pt to the right of a 60 pt wide button.
        let d = Fusion.distance(from: CGPoint(x: 200, y: 120), to: button)
        XCTAssertEqual(d, 40, accuracy: 0.001)
        // Inside is zero, not "half the width".
        XCTAssertEqual(Fusion.distance(from: CGPoint(x: 130, y: 120), to: button), 0)
    }

    // MARK: - Routing

    func testConfidentAXSkipsVisionEntirely() {
        XCTAssertFalse(Fusion.needsVision(axScore: 0.90, axHitThreshold: threshold,
                                          labelledFraction: 0.8))
    }

    func testNoAXMatchAlwaysNeedsVision() {
        XCTAssertTrue(Fusion.needsVision(axScore: nil, axHitThreshold: threshold,
                                         labelledFraction: 0.9))
    }

    func testWeakMatchInASparseAppNeedsVision() {
        XCTAssertTrue(Fusion.needsVision(axScore: 0.35, axHitThreshold: threshold,
                                         labelledFraction: 0.15))
    }

    /// A near-miss in a well-labelled app is usually odd phrasing, not a
    /// control the tree cannot see — and vision is unlikely to beat a good
    /// tree. Not worth two seconds.
    func testNearMissInAWellLabelledAppSkipsVision() {
        XCTAssertFalse(Fusion.needsVision(axScore: threshold * 0.8,
                                          axHitThreshold: threshold,
                                          labelledFraction: 0.85))
    }
}

final class ExclusionListTests: XCTestCase {

    func testBundlePrefixCoversHelpers() {
        let list = ExclusionList.defaults
        XCTAssertTrue(list.check(bundleID: "com.1password.1password7",
                                 windowTitle: "Vault").excluded)
        XCTAssertTrue(list.check(bundleID: "com.apple.mail", windowTitle: nil).excluded)
    }

    func testOrdinaryAppsAreAllowed() {
        let list = ExclusionList.defaults
        XCTAssertFalse(list.check(bundleID: "com.apple.logic10",
                                  windowTitle: "Untitled — Tracks").excluded)
    }

    /// The case a bundle list cannot express: the browser must stay usable,
    /// but a banking tab inside it must not be captured.
    func testTitleRuleCatchesTheBrowserTabCase() {
        let list = ExclusionList.defaults
        XCTAssertFalse(list.check(bundleID: "com.google.Chrome",
                                  windowTitle: "GitHub").excluded)
        let v = list.check(bundleID: "com.google.Chrome",
                           windowTitle: "Online Banking — Chase")
        XCTAssertTrue(v.excluded)
        XCTAssertNotNil(v.reason, "a silent refusal looks like a bug")
    }

    func testVerdictExplainsWhichRuleFired() {
        let v = ExclusionList.defaults.check(bundleID: "com.apple.passwords",
                                             windowTitle: nil)
        XCTAssertTrue(v.reason?.contains("com.apple.passwords") ?? false)
    }

    func testRoundTripsThroughText() {
        var list = ExclusionList(rules: [])
        list.add(.init(kind: .bundleID, pattern: "com.example.bank"))
        list.add(.init(kind: .titleContains, pattern: "salary review"))
        let reparsed = ExclusionList.parse(list.serialized())
        XCTAssertEqual(reparsed.rules.count, 2)
        XCTAssertTrue(reparsed.check(bundleID: "com.example.bank.helper",
                                     windowTitle: nil).excluded)
        XCTAssertTrue(reparsed.check(bundleID: "com.x", windowTitle: "Salary Review").excluded)
    }

    func testParserIgnoresCommentsAndJunk() {
        let list = ExclusionList.parse("""
        # a comment
        bundle: com.example.one

        nonsense line
        title:
        title: secret
        """)
        XCTAssertEqual(list.rules.count, 2)
    }

    func testAddIsIdempotent() {
        var list = ExclusionList(rules: [])
        list.add(.init(kind: .bundleID, pattern: "com.a"))
        list.add(.init(kind: .bundleID, pattern: "COM.A"))
        XCTAssertEqual(list.rules.count, 1)
    }

    func testRemoveWorks() {
        var list = ExclusionList.defaults
        let before = list.rules.count
        list.remove(kind: .bundleID, pattern: "com.apple.mail")
        XCTAssertEqual(list.rules.count, before - 1)
        XCTAssertFalse(list.check(bundleID: "com.apple.mail", windowTitle: nil).excluded)
    }
}
