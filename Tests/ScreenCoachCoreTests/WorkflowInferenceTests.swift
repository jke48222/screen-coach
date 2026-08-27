import XCTest
@testable import ScreenCoachCore

/// Recording is watching, and watching means deciding what a click *meant*.
/// Every decision here — which element was clicked, how to describe it, what
/// its effect was — is pinned against synthetic trees, because each one has a
/// wrong version that records confidently and replays garbage.
final class WorkflowInferenceTests: XCTestCase {

    private func node(_ id: Int, parent: Int? = nil, depth: Int = 1, role: String,
                      title: String? = nil, value: String? = nil, enabled: Bool = true,
                      rect: CGRect) -> AXNode {
        AXNode(id: id, parentID: parent, depth: depth, role: role, title: title,
               valueText: value, enabled: enabled,
               bounds: ScreenRect(cg: rect, screenIndex: 0))
    }

    /// A window holding a toolbar holding a button — the shape every real
    /// click lands in: point is inside all three.
    private var tree: [AXNode] {
        [node(0, role: "AXWindow", title: "Doc — Editor",
              rect: CGRect(x: 0, y: 0, width: 1200, height: 900)),
         node(1, parent: 0, depth: 1, role: "AXToolbar", title: "Toolbar",
              rect: CGRect(x: 0, y: 0, width: 1200, height: 60)),
         node(2, parent: 1, depth: 2, role: "AXButton", title: "Share",
              rect: CGRect(x: 500, y: 10, width: 80, height: 40)),
         node(3, parent: 0, depth: 1, role: "AXCheckBox", title: "Metronome",
              value: "0", rect: CGRect(x: 100, y: 200, width: 40, height: 40))]
    }

    // MARK: - Hit-testing

    func testClickResolvesToTheSmallestActionableElement() {
        let hit = WorkflowInference.hitTest(CGPoint(x: 520, y: 30), in: tree)
        XCTAssertEqual(hit?.title, "Share",
                       "the click is also inside the toolbar and the window — the button must win")
    }

    func testClickOnBareWindowRefusesRatherThanRecordingTheWindow() {
        // (300, 500) is inside only the window. "You clicked the window"
        // teaches nothing, so the honest answer is nil.
        XCTAssertNil(WorkflowInference.hitTest(CGPoint(x: 300, y: 500), in: tree))
    }

    func testClickOutsideEverythingIsNil() {
        XCTAssertNil(WorkflowInference.hitTest(CGPoint(x: 5000, y: 5000), in: tree))
    }

    // MARK: - Query synthesis

    func testQuerySpeaksTheResolversLanguage() {
        let q = WorkflowInference.semanticQuery(for: tree[2], in: tree)
        XCTAssertEqual(q, "the Share button in the Toolbar")
        // The synthesized query must round-trip through the resolver it was
        // written for — a recording that cannot re-find its own target on the
        // machine that made it will never survive a different one.
        let ranked = AXResolver.rank(query: q!, in: tree,
                                     windowBounds: ScreenRect(
                                        cg: CGRect(x: 0, y: 0, width: 1200, height: 900),
                                        screenIndex: 0))
        XCTAssertEqual(ranked.first?.node.id, 2)
        XCTAssertGreaterThanOrEqual(ranked.first?.score ?? 0, AXResolver.hitThreshold)
    }

    func testWindowTitleNeverBecomesTheContainerClause() {
        // The checkbox's only labelled ancestor is the window; its title names
        // the document, not a place, and polluting queries with it once cost
        // 5 of 12 exact hits.
        let q = WorkflowInference.semanticQuery(for: tree[3], in: tree)
        XCTAssertEqual(q, "the Metronome button")
    }

    func testCheckboxIsCalledAButtonForRoleAgreement() {
        // "checkbox" is resolver vocabulary too, but "button" covers
        // AXCheckBox in roleHints and is what people actually say.
        XCTAssertTrue(WorkflowInference.semanticQuery(for: tree[3], in: tree)!
            .hasSuffix("button"))
    }

    func testUnlabelledElementYieldsNoQuery() {
        let anon = node(9, role: "AXButton", rect: CGRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertNil(WorkflowInference.semanticQuery(for: anon, in: [anon]))
    }

    // MARK: - Completion inference

    func testToggleInfersTargetChanges() {
        var after = tree
        after[3] = node(3, parent: 0, role: "AXCheckBox", title: "Metronome",
                        value: "1", rect: CGRect(x: 100, y: 200, width: 40, height: 40))
        XCTAssertEqual(
            WorkflowInference.inferCompletion(clickedQuery: "the Metronome button",
                                              before: tree, after: after),
            .targetChanges)
    }

    func testOpeningASheetInfersElementAppears() {
        let after = tree + [node(7, parent: 0, role: "AXSheet", title: "Share Options",
                                 rect: CGRect(x: 300, y: 200, width: 600, height: 400))]
        XCTAssertEqual(
            WorkflowInference.inferCompletion(clickedQuery: "the Share button in the Toolbar",
                                              before: tree, after: after),
            .elementAppears("Share Options"))
    }

    /// When a sheet opens, the sheet is the event — not the dozen buttons
    /// that arrived inside it. Area picks the sheet.
    func testAppearancePicksTheSheetNotItsButtons() {
        let after = tree
            + [node(7, parent: 0, role: "AXSheet", title: "Share Options",
                    rect: CGRect(x: 300, y: 200, width: 600, height: 400)),
               node(8, parent: 7, depth: 2, role: "AXButton", title: "Copy Link",
                    rect: CGRect(x: 340, y: 500, width: 100, height: 30))]
        XCTAssertEqual(
            WorkflowInference.inferCompletion(clickedQuery: "the Share button in the Toolbar",
                                              before: tree, after: after),
            .elementAppears("Share Options"))
    }

    func testVanishingElementInfersDisappears() {
        var after = tree
        after.removeAll { $0.id == 2 }
        XCTAssertEqual(
            WorkflowInference.inferCompletion(clickedQuery: "the Share button in the Toolbar",
                                              before: tree, after: after),
            .elementDisappears("Share"))
    }

    func testNoObservableEffectFallsBackToManual() {
        XCTAssertEqual(
            WorkflowInference.inferCompletion(clickedQuery: "the Share button in the Toolbar",
                                              before: tree, after: tree),
            .manual)
    }

    /// Inference and replay must identify elements the same way. A completion
    /// inferred here has to actually fire when LessonEngine watches the same
    /// transition — otherwise recordings encode conditions replay can never
    /// observe, and every recorded lesson stalls on step one.
    func testInferredCompletionActuallyFiresInTheEngine() {
        let after = tree + [node(7, parent: 0, role: "AXSheet", title: "Share Options",
                                 rect: CGRect(x: 300, y: 200, width: 600, height: 400))]
        let completion = WorkflowInference.inferCompletion(
            clickedQuery: "the Share button in the Toolbar", before: tree, after: after)
        XCTAssertTrue(LessonEngine.isSatisfied(completion,
                                               target: "the Share button in the Toolbar",
                                               before: tree, after: after))
    }

    // MARK: - Label extraction

    func testLabelExtractionUndoesQuerySynthesis() {
        XCTAssertEqual(WorkflowInference.extractLabel(
            from: "the Gmail button in the Bookmarks"), "Gmail")
        XCTAssertEqual(WorkflowInference.extractLabel(from: "the Share button"), "Share")
        XCTAssertEqual(WorkflowInference.extractLabel(from: "the Chrome popup"), "Chrome")
    }

    // MARK: - Serialization

    func testLessonRoundTripsThroughReadableJSON() throws {
        let lesson = Lesson(title: "Share a document", bundleID: "com.example.editor",
                            steps: [
            Step(instruction: "Click Share", target: "the Share button in the Toolbar",
                 completion: .elementAppears("Share Options")),
            Step(instruction: "Toggle the metronome", target: "the Metronome button",
                 completion: .targetChanges),
            Step(instruction: "Close it", target: "the Close button",
                 completion: .elementDisappears("Share Options")),
            Step(instruction: "Admire your work", target: "the canvas",
                 completion: .manual),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(lesson)
        let text = String(data: data, encoding: .utf8)!

        // The file is the shareable artifact — it must be auditable by eye,
        // not synthesized-enum soup.
        XCTAssertTrue(text.contains("\"kind\" : \"appears\""))
        XCTAssertFalse(text.contains("_0"))

        let back = try JSONDecoder().decode(Lesson.self, from: data)
        XCTAssertEqual(back, lesson)
    }

    func testUnknownCompletionKindFailsLoudly() {
        let json = #"{"title":"x","steps":[{"instruction":"i","target":"t","completion":{"kind":"telepathy"}}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Lesson.self, from: Data(json.utf8)))
    }
}
