import AppKit
import ScreenCoachCore
import ScreenCoachKit

/// Two questions, both answered against a saved snapshot so the whole thing
/// is reproducible without the app being open.
///
/// **How often does the accessibility tree answer on its own?** This is the
/// number the entire architecture rests on. Phase 0 measured the vision
/// fallback at 1657 ms and 50% accuracy at best; AX resolution costs 21 ms and
/// is exact when it hits. So the value of the whole design is set by how often
/// it hits, and nothing else in Phase 0 measured that.
///
/// **When it misses, can it still aim the crop?** Finding 7 showed native-
/// resolution cropping is worth 3× the accuracy of downscaling at equal token
/// cost, and that a blind 3×3 grid already beat the full window. If the tree
/// can aim better than a blind grid, the two grounding paths stop being
/// alternatives and start cooperating.
enum AXPlan {

    struct Snapshot {
        let nodes: [AXNode]
        let targets: [(node: AXNode, query: String, px: [Double])]
        let windowPx: ScreenRect
        let imageSize: [Int]
    }

    /// Phrase a target the way a person would, matching `describe()` in the
    /// Python harness so both halves ask the identical question.
    static func describe(role: String, title: String) -> String {
        let bare = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        let noun: String
        switch bare {
        case "CheckBox", "Button": noun = "button"
        case "MenuItem": noun = "menu item"
        case "PopUpButton": noun = "pop-up button"
        case "TextField": noun = "text field"
        case "Image": noun = "image"
        case "StaticText": noun = "label"
        case "Row": noun = "row"
        case "Cell": noun = "cell"
        case "Tab": noun = "tab"
        case "Link": noun = "link"
        default: noun = bare.lowercased()
        }
        return "the \(title) \(noun)"
    }

    /// The human-readable name of an element, from wherever the app put it.
    ///
    /// Chrome labels its toolbar buttons through AXDescription and leaves
    /// AXTitle empty; AppKit apps usually do the opposite. Requiring a title
    /// discarded every Chrome control and produced a snapshot with zero
    /// targets — so the label is whichever field actually carries it.
    static func bestLabel(_ n: AXNode) -> String? {
        for candidate in [n.title, n.roleDescription, n.helpText] {
            if let c = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               c.count >= 2 { return c }
        }
        return nil
    }

    static func load(_ path: String) -> Snapshot? {
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawNodes = root["nodes"] as? [[String: Any]],
              let rawTargets = root["targets"] as? [[String: Any]],
              let size = root["image_size"] as? [Int] else { return nil }

        func rect(_ a: [Double]) -> ScreenRect {
            ScreenRect(cg: CGRect(x: a[0], y: a[1], width: a[2], height: a[3]),
                       screenIndex: 0)
        }
        func str(_ d: [String: Any], _ k: String) -> String? {
            let v = d[k] as? String
            return (v?.isEmpty ?? true) ? nil : v
        }

        // Node bounds are already in window-pixel space in the snapshot, and
        // the resolver only ever compares them to each other, so keeping
        // that frame throughout avoids a conversion that could only add a
        // bug. Screen index is fixed at 0 for the same reason.
        var nodes: [AXNode] = []
        for d in rawNodes {
            guard let id = d["id"] as? Int, let role = d["role"] as? String,
                  let px = d["px"] as? [Double], px.count == 4 else { continue }
            let parent = d["parent"] as? Int
            nodes.append(AXNode(
                id: id, parentID: (parent ?? -1) < 0 ? nil : parent,
                depth: d["depth"] as? Int ?? 0, role: role,
                title: str(d, "title"), roleDescription: str(d, "desc"),
                helpText: str(d, "help"), identifier: str(d, "identifier"),
                enabled: d["enabled"] as? Bool ?? true, bounds: rect(px)
            ))
        }

        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let extent = nodes.reduce(CGRect.null) { $0.union($1.bounds.cg) }
        let extentArea = extent.isNull ? 0 : extent.width * extent.height

        /// Nearest labelled ancestor that names a PLACE.
        func container(of node: AXNode) -> String? {
            var cursor = node.parentID
            var hops = 0
            while let id = cursor, hops < 6, let parent = byID[id] {
                // A container hint has to name a PLACE, not the document.
                //
                // Chrome hangs the page title off both the AXWindow and a
                // full-window AXGroup, so excluding the window role alone was
                // not enough. Feeding "the Back button in the Delivery Driver
                // Shorts" to the resolver injects page-title words that match
                // nothing and dropped exact hits from 12/12 to 7/12.
                //
                // Two properties separate a region from a document title: a
                // region is named briefly ("Bookmarks", "Sidebar"), and it
                // occupies part of the UI rather than all of it.
                if parent.isContainer, parent.role != "AXWindow",
                   let l = bestLabel(parent), l.count >= 3, l.count <= 24 {
                    let a = parent.bounds.cg.width * parent.bounds.cg.height
                    if extentArea <= 0 || a / extentArea < 0.6 { return l }
                }
                cursor = parent.parentID
                hops += 1
            }
            return nil
        }

        var targets: [(AXNode, String, [Double])] = []
        for d in rawTargets {
            guard let id = d["id"] as? Int, let node = byID[id],
                  let px = d["px"] as? [Double],
                  let label = bestLabel(node) else { continue }
            // Phrase it the way the brief specifies the reasoning model
            // should: "the Preferences item in the app menu" — the container
            // is part of the request, not an afterthought. It is also the
            // only thing left to aim at when the element itself is missing,
            // so omitting it under-tests the AX-assisted crop.
            var query = describe(role: node.role, title: label)
            if let c = container(of: node), !label.lowercased().contains(c.lowercased()) {
                query += " in the \(c)"
            }
            targets.append((node, query, px))
        }

        // The reference extent is the UNION OF THE AX NODES, not any single
        // window frame.
        //
        // Chrome spreads one browser window across three separate SCWindows —
        // 1512×827 for the page, plus 1512×174 and 1512×81 strips carrying the
        // tabs and toolbar — while its accessibility tree spans all of them.
        // Clamping to the largest frame put every toolbar control outside the
        // reference rect, so crops were intersected down to nothing and the
        // size penalty was calibrated against the wrong area.
        //
        // The region an app's accessibility tree actually occupies is the only
        // definition that survives that, and it needs no window frame at all.
        let union = nodes.reduce(CGRect.null) { $0.union($1.bounds.cg) }
        let win = union.isNull
            ? CGRect(x: 0, y: 0, width: Double(size[0]), height: Double(size[1]))
            : union

        return Snapshot(
            nodes: nodes, targets: targets,
            windowPx: ScreenRect(cg: win, screenIndex: 0),
            imageSize: size
        )
    }

    /// Same sampling rule as the Python harness so the two report on the same
    /// targets: deduplicated by label and by coarse position, so a hundred
    /// near-identical channel strips cannot pass for coverage.
    static func sample(_ snap: Snapshot, count: Int) -> [(node: AXNode, query: String, px: [Double])] {
        var seenLabels = Set<String>()
        var seenCells = Set<String>()
        var pool: [(AXNode, String, [Double])] = []
        for t in snap.targets {
            guard let title = bestLabel(t.node) else { continue }
            let cx = t.px[0] + t.px[2] / 2, cy = t.px[1] + t.px[3] / 2
            let cell = "\(Int(cx / 150)),\(Int(cy / 150))"
            guard !seenLabels.contains(title.lowercased()), !seenCells.contains(cell) else { continue }
            seenLabels.insert(title.lowercased())
            seenCells.insert(cell)
            pool.append(t)
        }
        // Python shuffles with Random(0); reproducing that exactly across
        // languages is not worth it, so the plan file carries the chosen
        // targets and the Python side reads them from it.
        return Array(pool.prefix(count))
    }

    static func run(dataPath: String, outPath: String, count: Int) {
        guard let snap = load(dataPath) else {
            print("  Could not load \(dataPath) — re-run `snap` to regenerate it with node data.")
            return
        }
        let chosen = sample(snap, count: count)
        guard !chosen.isEmpty else {
            print("  No usable targets in \(dataPath) — nothing to measure.")
            return
        }
        print("\n\u{001B}[1m── AX RESOLVER \u{001B}[0m")
        print("  \(snap.nodes.count) nodes, \(snap.targets.count) labelled targets, "
              + "measuring \(chosen.count)\n")

        var hits = 0, top3 = 0
        var resolveTimes: [Double] = []
        var plans: [[String: Any]] = []

        for t in chosen {
            // (1) Can the tree answer outright?
            let t0 = Mono.nowNs()
            let ranked = AXResolver.rank(query: t.query, in: snap.nodes,
                                         windowBounds: snap.windowPx, limit: 3)
            resolveTimes.append(Mono.msSince(t0))
            let isHit = ranked.first?.node.id == t.node.id
                && (ranked.first?.score ?? 0) >= AXResolver.hitThreshold
            if isHit { hits += 1 }
            if ranked.contains(where: { $0.node.id == t.node.id }) { top3 += 1 }

            // (2) If it could not, could it still aim the crop? Ablating the
            // target and everything under it simulates the real miss: a tree
            // that exposes structure but not this control.
            var excluded: Set<Int> = [t.node.id]
            var changed = true
            while changed {
                changed = false
                for n in snap.nodes where !excluded.contains(n.id) {
                    if let p = n.parentID, excluded.contains(p) {
                        excluded.insert(n.id); changed = true
                    }
                }
            }
            let hint = AXResolver.cropHint(query: t.query, in: snap.nodes,
                                           windowBounds: snap.windowPx,
                                           excluding: excluded)
            let r = hint.rect.cg
            let winArea = snap.windowPx.cg.width * snap.windowPx.cg.height
            let frac = (r.width * r.height) / winArea
            let target = CGRect(x: t.px[0], y: t.px[1], width: t.px[2], height: t.px[3])
            let contains = r.contains(target)

            plans.append([
                "id": t.node.id, "query": t.query,
                "target_px": t.px,
                "ax_hit": isHit,
                "ax_score": Double(ranked.first?.score ?? 0),
                "ax_top": ranked.first.map { "\($0.node.role):\($0.node.title ?? "")" } ?? "",
                "crop_px": [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)],
                "crop_fraction": Double(frac),
                "crop_contains_target": contains,
                "crop_source": hint.source,
                "crop_confidence": Double(hint.confidence),
                "crop_whole_window": hint.isWholeWindow,
            ])

            let mark = isHit ? "HIT " : "miss"
            print("  \(mark) score \(String(format: "%.2f", ranked.first?.score ?? 0))  "
                  + "crop \(String(format: "%4.0f%%", frac * 100)) "
                  + (contains ? "covers " : "MISSES ")
                  + "  \(t.query.prefix(40))")
        }

        let n = Double(chosen.count)
        let covered = plans.filter { ($0["crop_contains_target"] as? Bool) ?? false }.count
        let whole = plans.filter { ($0["crop_whole_window"] as? Bool) ?? false }.count
        let meanFrac = plans.compactMap { $0["crop_fraction"] as? Double }.reduce(0, +) / n
        let times = LatencySamples(stage: .axResolve, values: resolveTimes)

        print("""

          AX resolve      \(hits)/\(chosen.count) exact hits (\(String(format: "%.0f%%", Double(hits) / n * 100))), \
        \(top3)/\(chosen.count) in top-3
          resolve cost    \(String(format: "%.3f ms p50, %.3f ms p90", times.p50, times.p90)) \
        (budget 20 ms)
          aimed crop      \(covered)/\(chosen.count) contain the target, \
        mean \(String(format: "%.0f%%", meanFrac * 100)) of window, \(whole) fell back to whole window
        """)

        let payload: [String: Any] = [
            "source": dataPath, "image_size": snap.imageSize,
            "ax_hit_rate": Double(hits) / n,
            "resolve_p50_ms": times.p50, "resolve_p90_ms": times.p90,
            "plans": plans,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("\n  Wrote \(outPath)")
        }
    }
}
