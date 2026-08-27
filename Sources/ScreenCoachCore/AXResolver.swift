import CoreGraphics
import Foundation

/// Resolving a natural-language target against the accessibility tree.
///
/// This is step 3 of the pipeline: the reasoning model names a target the way
/// a person would — "the Preferences item in the app menu" — and this turns
/// that into a specific element with exact bounds. When it succeeds there is
/// no vision inference at all.
///
/// The scorer is lexical rather than embedding-based, deliberately, for now.
/// UI labels are short, literal, and drawn from a small vocabulary; the phrase
/// a user says and the string in `AXTitle` are usually the same words. That is
/// the regime where token overlap is strong and a 600M-parameter embedding
/// model is mostly latency. Phase 0 measured the vision fallback at 1.7 ms per
/// image token, so the bar for adding another model to the hot path is high.
/// `resolveHitRate` in the bench exists to check that assumption rather than
/// assert it — if lexical matching plateaus, embeddings are the upgrade.
public enum AXResolver {

    public struct Candidate: Equatable {
        public let node: AXNode
        public let score: Double
        /// Which field carried the match — useful when a result looks wrong.
        public let matchedOn: String

        public init(node: AXNode, score: Double, matchedOn: String) {
            self.node = node
            self.score = score
            self.matchedOn = matchedOn
        }
    }

    /// Words that carry no discriminating signal in a UI query. "Button" and
    /// friends are handled separately as role hints rather than dropped —
    /// they are weak evidence, not noise.
    static let stopWords: Set<String> = [
        "the", "a", "an", "of", "in", "on", "at", "to", "for", "with",
        "please", "click", "press", "select", "choose", "find", "open",
        "my", "this", "that", "it", "is", "and", "or",
    ]

    /// Query words that name a role rather than an element, mapped to the AX
    /// roles they imply.
    static let roleHints: [String: Set<String>] = [
        "button": ["AXButton", "AXCheckBox", "AXPopUpButton", "AXToolbarButton", "AXRadioButton"],
        "checkbox": ["AXCheckBox"], "toggle": ["AXCheckBox", "AXSwitch"],
        "switch": ["AXSwitch", "AXCheckBox"],
        "menu": ["AXMenu", "AXMenuItem", "AXMenuBarItem"],
        "item": ["AXMenuItem", "AXCell", "AXRow"],
        "field": ["AXTextField", "AXTextArea", "AXComboBox"],
        "text": ["AXTextField", "AXTextArea", "AXStaticText"],
        "box": ["AXTextField", "AXCheckBox", "AXComboBox"],
        "slider": ["AXSlider"], "tab": ["AXTab", "AXTabGroup"],
        "link": ["AXLink"], "image": ["AXImage"], "icon": ["AXImage", "AXButton"],
        "label": ["AXStaticText"], "row": ["AXRow"], "cell": ["AXCell"],
        "list": ["AXList", "AXOutline", "AXTable"],
        "popup": ["AXPopUpButton"], "dropdown": ["AXPopUpButton", "AXComboBox"],
    ]

    public struct Query {
        public let raw: String
        public let terms: [String]
        public let termSet: Set<String>
        public let impliedRoles: Set<String>

        public init(_ raw: String) {
            self.raw = raw
            let all = AXResolver.tokenize(raw)
            var roles = Set<String>()
            var kept: [String] = []
            for t in all {
                if let r = AXResolver.roleHints[t] {
                    roles.formUnion(r)
                    // A role word is also still a content word: "the Play
                    // button" versus a literal element titled "Button".
                    kept.append(t)
                } else if !AXResolver.stopWords.contains(t) {
                    kept.append(t)
                }
            }
            self.terms = kept
            self.termSet = Set(kept)
            self.impliedRoles = roles
        }

        /// Terms excluding role words — the part that actually identifies
        /// *which* button, which is what should dominate the score.
        public var contentTerms: Set<String> {
            termSet.filter { AXResolver.roleHints[$0] == nil }
        }
    }

    public static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    // MARK: - Scoring

    /// How much of `query` is present in `field`, weighted so that covering
    /// all the query's content words matters more than the field being short.
    /// Field length is only lightly penalised: AX help text is often a whole
    /// sentence and should not be punished for it.
    static func coverage(_ query: Set<String>, _ field: String) -> Double {
        guard !query.isEmpty else { return 0 }
        let fieldTokens = Set(tokenize(field))
        guard !fieldTokens.isEmpty else { return 0 }
        let hits = query.intersection(fieldTokens).count
        guard hits > 0 else { return 0 }
        let recall = Double(hits) / Double(query.count)
        let precision = Double(hits) / Double(fieldTokens.count)
        // Recall-dominant: finding every query word in a verbose label is a
        // better signal than a terse label matching one word.
        return recall * 0.85 + precision * 0.15
    }

    public static func score(_ q: Query, _ node: AXNode,
                             windowArea: CGFloat) -> (score: Double, field: String) {
        let content = q.contentTerms.isEmpty ? q.termSet : q.contentTerms

        var best = 0.0
        var bestField = "none"
        // Title is the strongest signal, then description, then help, then
        // the identifier (developer-facing but often descriptive).
        let fields: [(String, String?, Double)] = [
            ("title", node.title, 1.00),
            ("description", node.roleDescription, 0.85),
            ("help", node.helpText, 0.55),
            ("identifier", node.identifier, 0.45),
            ("value", node.valueText, 0.40),
        ]
        for (name, text, weight) in fields {
            guard let text, !text.isEmpty else { continue }
            let c = coverage(content, text) * weight
            if c > best { best = c; bestField = name }

            // Exact title equality is close to certainty and deserves to
            // outrank any amount of partial overlap elsewhere.
            if name == "title",
               tokenize(text) == Array(content).sorted() || text.lowercased() == q.raw.lowercased() {
                best = Swift.max(best, 1.0)
                bestField = "title(exact)"
            }
        }
        guard best > 0 else { return (0, "none") }

        var total = best

        // Role agreement, as a multiplier on disagreement.
        //
        // A flat -0.06 was far too weak: a static text reading "Play" scores
        // a perfect title match against "the Play button" and stayed above
        // the hit threshold on text alone. Role is the only thing separating
        // a control from a label describing it, so disagreement has to
        // actually cost something. Containers are exempt — a group is never
        // the answer, but it is a legitimate crop target.
        if !q.impliedRoles.isEmpty, !node.isContainer {
            if q.impliedRoles.contains(node.role) { total += 0.12 }
            else { total *= 0.55 }
        }
        if node.isActionable { total += 0.05 }
        if !node.enabled { total -= 0.10 }

        // Size penalty, applied as a multiplier rather than a subtraction.
        //
        // A container spanning the window will happily match any word in any
        // descendant's label — and an AXWindow's own title matches the
        // document name exactly, which used to score a perfect 1.0 and sail
        // past the hit threshold even after a flat penalty. Pointing at it is
        // the classic near-miss: technically contains the target, useless as
        // an answer. Scaling means no amount of textual agreement can promote
        // a window-sized element into a confident hit.
        let area = node.bounds.cg.width * node.bounds.cg.height
        guard area > 0 else { return (0, "zero-size") }

        if windowArea > 0 {
            let fraction = Double(area / windowArea)
            if fraction > 0.5 { total *= 0.35 }
            else if fraction > 0.25 { total *= 0.60 }
            else if fraction > 0.10 { total *= 0.85 }
        }

        return (total, bestField)
    }

    // MARK: - Ranking

    public static func rank(query: String, in nodes: [AXNode],
                            windowBounds: ScreenRect? = nil,
                            excluding excluded: Set<Int> = [],
                            limit: Int = 5) -> [Candidate] {
        let q = Query(query)
        let windowArea = windowBounds.map { $0.cg.width * $0.cg.height } ?? 0
        var out: [Candidate] = []
        for node in nodes where !excluded.contains(node.id) && node.hasLabel {
            let (s, field) = score(q, node, windowArea: windowArea)
            guard s > 0 else { continue }
            out.append(Candidate(node: node, score: s, matchedOn: field))
        }
        out.sort { $0.score > $1.score }
        return Array(out.prefix(limit))
    }

    /// How completely a node's labels contain the query's content words.
    ///
    /// Distinct from `score`, which answers "is this the best thing to point
    /// at" and is deliberately tolerant of partial matches. Presence asks a
    /// stricter, narrower question — "does something matching this
    /// description exist" — and needs recall, not ranking. Lowering the
    /// ranking threshold instead let a "Preferences" button satisfy a check
    /// for a "Preferences Window", so a dialog looked open before it opened.
    public static func presenceRecall(query: String, node: AXNode) -> Double {
        let q = Query(query)
        let content = q.contentTerms.isEmpty ? q.termSet : q.contentTerms
        guard !content.isEmpty else { return 0 }
        var best = 0.0
        for field in [node.title, node.roleDescription, node.helpText, node.identifier] {
            guard let field, !field.isEmpty else { continue }
            let tokens = Set(tokenize(field))
            let hit = Double(content.intersection(tokens).count) / Double(content.count)
            best = Swift.max(best, hit)
        }
        return best
    }

    /// Confidence threshold for treating a match as a hit rather than a
    /// guess. Below this the coach should not point confidently — it should
    /// fall through to vision, or render the uncertain state.
    public static let hitThreshold = 0.62

    // MARK: - Aiming the vision fallback

    public struct CropHint: Equatable {
        public let rect: ScreenRect
        /// What the crop was derived from, for the record.
        public let source: String
        public let confidence: Double
        /// True when nothing in the tree scored well enough to narrow down,
        /// so the crop is just the whole window.
        public let isWholeWindow: Bool
    }

    /// Aim the vision fallback using whatever the tree still knows.
    ///
    /// This is the finding from Phase 0 turned into code. Cropping at native
    /// resolution was worth 3× the accuracy of downscaling to the same token
    /// cost, and a fixed grid cell already beat the full window on both speed
    /// and accuracy. But a fixed grid is a blunt instrument — it does not know
    /// where anything is. The tree usually does, even when it cannot name the
    /// exact element: a canvas app still exposes its panels, an uncooperative
    /// Electron window still exposes its toolbar.
    ///
    /// So on an AX miss, rank anyway, take the best surviving region, pad it,
    /// and hand the model a small native-resolution crop instead of a large
    /// downscaled window.
    public static func cropHint(query: String, in nodes: [AXNode],
                                windowBounds: ScreenRect,
                                excluding excluded: Set<Int> = [],
                                padding: Double = 0.35,
                                minFraction: Double = 0.02) -> CropHint {
        let ranked = rank(query: query, in: nodes, windowBounds: windowBounds,
                          excluding: excluded, limit: 4)

        guard let best = ranked.first, best.score > 0.18,
              best.node.bounds.cg.width > 0, best.node.bounds.cg.height > 0 else {
            return CropHint(rect: windowBounds, source: "no usable match",
                            confidence: 0, isWholeWindow: true)
        }

        // Only bet the crop on a hint worth trusting.
        //
        // The errors here are wildly asymmetric. Cropping too wide costs
        // tokens — Phase 0 measured that at about 1.7 ms each, so a bad crop
        // is a slow answer. Cropping tight in the *wrong place* puts the
        // target outside the image entirely, and no amount of model quality
        // recovers from being shown the wrong region. So a match that names
        // the right words but the wrong kind of thing — a status label
        // reading "Play" when the query wanted a Play button — is treated as
        // no hint at all rather than as a confident one.
        let q = Query(query)
        let roleDisagrees = !q.impliedRoles.isEmpty
            && !q.impliedRoles.contains(best.node.role)
            && !best.node.isContainer
        if roleDisagrees {
            return CropHint(rect: windowBounds,
                            source: "best match \(best.node.role) contradicts the requested role",
                            confidence: best.score, isWholeWindow: true)
        }

        // Cover every candidate competitive with the best, not just the best.
        //
        // This is the AX-miss path, so the exact element is by definition not
        // what matched — which means the top match is often the *wrong
        // instance* of an ambiguous label. A toolbar "Play" button and a
        // status label reading "Play" score alike; betting the crop on
        // whichever edged ahead aims it at the wrong half of the window and
        // the fallback cannot recover. Taking the union of near-ties hedges
        // that, and shrinks back to a tight crop whenever the best match is
        // unambiguous.
        let competitive = ranked.filter { $0.score >= best.score * 0.6 }
        var r = competitive.dropFirst().reduce(best.node.bounds.cg) { acc, c in
            acc.union(c.node.bounds.cg)
        }

        // If the request names a region, trust the region over the element.
        //
        // Measured failure this fixes: the query was "the YouTube button in
        // the Bookmarks", and the page had *two* bookmarks named YouTube.
        // With the real target ablated, its twin was the only survivor, so
        // the crop landed tightly on the wrong one and excluded the target
        // entirely — unrecoverable, and the single miss in the whole run.
        //
        // The container is the more reliable signal precisely because it is
        // coarse: an ambiguous element name can point at the wrong instance,
        // but "the Bookmarks bar" is one place and contains every candidate.
        // Ranking alone will not surface it, since containers are deliberately
        // size-penalised to stop them winning as answers.
        // Union EVERY qualifying region, not the smallest one.
        //
        // Picking the smallest looked tidier and was wrong: for "the YouTube
        // button in the Bookmarks" a tiny group also labelled "YouTube"
        // outranked the Bookmarks bar on size, so the crop stayed on the
        // wrong side of the window. Choosing between regions requires knowing
        // which one the user meant, which is the thing we do not know; taking
        // all of them costs a few hundred image tokens and cannot exclude the
        // target. Each is still individually capped so one oversized group
        // cannot silently widen the crop to the whole app.
        let winA = windowBounds.cg.width * windowBounds.cg.height
        let content = q.contentTerms.isEmpty ? q.termSet : q.contentTerms
        for node in nodes
        where !excluded.contains(node.id) && node.isContainer && node.hasLabel {
            // Raw word overlap, not the ranking score.
            //
            // `score` weights AXDescription at 0.85 and help at 0.55 because
            // those are weaker evidence about *which control* something is.
            // That calibration is wrong for regions: Chrome names its
            // Bookmarks bar through AXDescription, so the correct region
            // scored 0.489 against a 0.5 bar and was skipped, leaving the
            // crop on the wrong half of the window. Whether a region shares
            // the query's words does not depend on which attribute the app
            // chose to store its name in.
            let overlap = [node.title, node.roleDescription, node.helpText]
                .compactMap { $0 }
                .map { coverage(content, $0) }
                .max() ?? 0
            guard overlap >= 0.45 else { continue }
            let c = node.bounds.cg
            guard c.width > 0, c.height > 0 else { continue }
            guard winA <= 0 || (c.width * c.height) / winA < 0.6 else { continue }
            r = r.union(c)
        }

        // If hedging ballooned the crop past half the window it has stopped
        // being a hint. Fall back to the single best match — a tight crop in
        // possibly the wrong place still beats a huge one, since the whole
        // point is native resolution on few tokens.
        let winArea0 = windowBounds.cg.width * windowBounds.cg.height
        if winArea0 > 0, (r.width * r.height) / winArea0 > 0.5 {
            r = best.node.bounds.cg
        }

        // A high-scoring container is a *region* hint; a high-scoring small
        // control is a *point* hint. Either way we want surrounding context,
        // because the element we actually want is near it, not inside it —
        // this is the AX-miss path, so the exact target is by definition not
        // what matched.
        let padX = Swift.max(r.width * padding, 48)
        let padY = Swift.max(r.height * padding, 48)
        r = r.insetBy(dx: -padX, dy: -padY)

        // Never let the crop collapse to something too small to give the
        // model context to work with.
        let winArea = windowBounds.cg.width * windowBounds.cg.height
        if winArea > 0, (r.width * r.height) / winArea < CGFloat(minFraction) {
            let target = (winArea * CGFloat(minFraction)).squareRoot()
            let grow = Swift.max(0, (target - Swift.min(r.width, r.height)) / 2)
            r = r.insetBy(dx: -grow, dy: -grow)
        }

        r = r.intersection(windowBounds.cg)
        guard !r.isNull, r.width > 0, r.height > 0 else {
            return CropHint(rect: windowBounds, source: "crop fell outside window",
                            confidence: 0, isWholeWindow: true)
        }

        let whole = r.width >= windowBounds.cg.width * 0.98
                 && r.height >= windowBounds.cg.height * 0.98
        return CropHint(
            rect: ScreenRect(cg: r, screenIndex: windowBounds.screenIndex),
            source: "\(best.node.role):\(best.node.title ?? best.matchedOn)",
            confidence: best.score, isWholeWindow: whole
        )
    }
}
