import XCTest
@testable import ScreenCoachCore

/// Auto-advance is the claim that separates this from a tutorial video, so the
/// completion rules are tested against synthetic before/after trees rather
/// than trusted to work live.
final class LessonTests: XCTestCase {

    private let window = ScreenRect(cg: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                    screenIndex: 0)

    private func node(_ id: Int, role: String, title: String, value: String? = nil,
                      enabled: Bool = true,
                      rect: CGRect = CGRect(x: 10, y: 10, width: 60, height: 30)) -> AXNode {
        AXNode(id: id, parentID: nil, depth: 1, role: role, title: title,
               valueText: value, enabled: enabled,
               bounds: ScreenRect(cg: rect, screenIndex: 0))
    }

    private var closed: [AXNode] {
        [node(0, role: "AXButton", title: "Preferences"),
         node(1, role: "AXCheckBox", title: "Metronome", value: "0")]
    }

    private var opened: [AXNode] {
        closed + [node(2, role: "AXSheet", title: "Preferences Window",
                       rect: CGRect(x: 200, y: 200, width: 400, height: 300))]
    }

    // MARK: - Appearance

    func testDialogOpeningCompletesTheStep() {
        XCTAssertTrue(LessonEngine.isSatisfied(
            .elementAppears("the Preferences Window"), target: "the Preferences button",
            before: closed, after: opened, windowBounds: window))
    }

    func testNothingHappeningDoesNotComplete() {
        XCTAssertFalse(LessonEngine.isSatisfied(
            .elementAppears("the Preferences Window"), target: "the Preferences button",
            before: closed, after: closed, windowBounds: window))
    }

    /// A step must not complete just because the element was already there —
    /// otherwise every step whose target exists at the start auto-advances
    /// instantly and the lesson races to the end without the user doing a
    /// thing.
    func testAlreadyPresentElementDoesNotCount() {
        XCTAssertFalse(LessonEngine.isSatisfied(
            .elementAppears("the Preferences Window"), target: "x",
            before: opened, after: opened, windowBounds: window))
    }

    func testDismissalCompletesADisappearStep() {
        XCTAssertTrue(LessonEngine.isSatisfied(
            .elementDisappears("the Preferences Window"), target: "x",
            before: opened, after: closed, windowBounds: window))
        XCTAssertFalse(LessonEngine.isSatisfied(
            .elementDisappears("the Preferences Window"), target: "x",
            before: closed, after: opened, windowBounds: window))
    }

    // MARK: - Value changes

    func testTogglingACheckboxCompletesTheStep() {
        var after = closed
        after[1] = node(1, role: "AXCheckBox", title: "Metronome", value: "1")
        XCTAssertTrue(LessonEngine.isSatisfied(
            .targetChanges, target: "the Metronome checkbox",
            before: closed, after: after, windowBounds: window))
    }

    func testUnchangedValueDoesNotComplete() {
        XCTAssertFalse(LessonEngine.isSatisfied(
            .targetChanges, target: "the Metronome checkbox",
            before: closed, after: closed, windowBounds: window))
    }

    func testBecomingEnabledCounts() {
        var after = closed
        after[0] = node(0, role: "AXButton", title: "Preferences", enabled: false)
        XCTAssertTrue(LessonEngine.isSatisfied(
            .targetChanges, target: "the Preferences button",
            before: closed, after: after, windowBounds: window))
    }

    /// A control that moved usually means a panel opened around it, which is
    /// weaker evidence than a value change but still evidence.
    func testMovingCounts() {
        var after = closed
        after[0] = node(0, role: "AXButton", title: "Preferences",
                        rect: CGRect(x: 500, y: 400, width: 60, height: 30))
        XCTAssertTrue(LessonEngine.isSatisfied(
            .targetChanges, target: "the Preferences button",
            before: closed, after: after, windowBounds: window))
    }

    func testUnresolvableTargetNeverCompletes() {
        XCTAssertFalse(LessonEngine.isSatisfied(
            .targetChanges, target: "the flux capacitor",
            before: closed, after: opened, windowBounds: window))
    }

    /// Some steps genuinely cannot be observed — a brush stroke, a colour
    /// pick. Saying so beats inventing a condition that fires at random.
    func testManualNeverAutoCompletes() {
        XCTAssertFalse(LessonEngine.isSatisfied(
            .manual, target: "anything", before: closed, after: opened, windowBounds: window))
    }

    // MARK: - Progress

    func testProgressWalksAndFinishes() {
        var p = LessonProgress(lesson: Lesson(title: "Test", steps: [
            Step(instruction: "One", target: "a"),
            Step(instruction: "Two", target: "b"),
        ]))
        XCTAssertEqual(p.stepNumber, 1)
        XCTAssertEqual(p.caption, "1/2  One")
        p.advance()
        XCTAssertEqual(p.stepNumber, 2)
        p.advance()
        XCTAssertTrue(p.isFinished)
        XCTAssertNil(p.current)
        XCTAssertEqual(p.completed, [0, 1])
    }

    func testAdvancingPastTheEndIsSafe() {
        var p = LessonProgress(lesson: Lesson(title: "T", steps: [
            Step(instruction: "Only", target: "a"),
        ]))
        p.advance()
        p.advance()
        XCTAssertTrue(p.isFinished)
        XCTAssertEqual(p.completed, [0])
    }

    func testGoingBackKeepsTheCompletionRecord() {
        var p = LessonProgress(lesson: Lesson(title: "T", steps: [
            Step(instruction: "One", target: "a"),
            Step(instruction: "Two", target: "b"),
        ]))
        p.advance()
        p.back()
        XCTAssertEqual(p.stepNumber, 1)
        XCTAssertEqual(p.completed, [0], "stepping back to look again is not un-learning")
    }

    func testBackAtTheStartIsSafe() {
        var p = LessonProgress(lesson: Lesson(title: "T", steps: [
            Step(instruction: "One", target: "a"),
        ]))
        p.back()
        XCTAssertEqual(p.stepNumber, 1)
    }
}

/// The `{app}` template exists for one hard case — Settings lives in a menu
/// named after the app — so substitution is pinned everywhere it must reach.
final class StepTemplateTests: XCTestCase {

    func testSubstitutionReachesEveryField() {
        let step = Step(instruction: "Open the {app} menu",
                        target: "the {app} menu",
                        completion: .elementAppears("{app} Settings"))
        let r = step.resolved(appName: "Calendar")
        XCTAssertEqual(r.instruction, "Open the Calendar menu")
        XCTAssertEqual(r.target, "the Calendar menu")
        XCTAssertEqual(r.completion, .elementAppears("Calendar Settings"))
    }

    func testTemplateFreeStepsPassThroughUntouched() {
        let step = Step(instruction: "Click Share", target: "the Share button",
                        completion: .targetChanges)
        XCTAssertEqual(step.resolved(appName: "Calendar"), step)
    }

    /// The resolved query must actually work against a menu-bar-shaped tree —
    /// the whole point of the template plus the extractor's menu gating.
    func testResolvedMenuQueryFindsTheMenuBarItem() {
        let bar = [
            AXNode(id: 0, parentID: nil, depth: 0, role: "AXMenuBar",
                   identifier: "main-menu-bar",
                   bounds: ScreenRect(cg: CGRect(x: 0, y: 0, width: 1512, height: 33),
                                      screenIndex: 0)),
            AXNode(id: 1, parentID: 0, depth: 1, role: "AXMenuBarItem", title: "Apple",
                   bounds: ScreenRect(cg: CGRect(x: 10, y: 0, width: 34, height: 33),
                                      screenIndex: 0)),
            AXNode(id: 2, parentID: 0, depth: 1, role: "AXMenuBarItem", title: "Calendar",
                   bounds: ScreenRect(cg: CGRect(x: 43, y: 0, width: 79, height: 33),
                                      screenIndex: 0)),
        ]
        let step = Step(instruction: "", target: "the {app} menu")
            .resolved(appName: "Calendar")
        let ranked = AXResolver.rank(query: step.target, in: bar, limit: 1)
        XCTAssertEqual(ranked.first?.node.id, 2)
        XCTAssertGreaterThanOrEqual(ranked.first?.score ?? 0, AXResolver.hitThreshold)
    }
}
