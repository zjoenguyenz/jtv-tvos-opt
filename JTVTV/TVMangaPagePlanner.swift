import CoreGraphics
import Foundation

/// One page of a manga image in PIXEL space: a contiguous
/// vertical crop of the decoded image (y from the image's top,
/// matching CGImage.cropping's coordinate convention — the
/// convention the 1.3.2 reader's fixed cuts already use).
struct TVMangaPageRect: Equatable {
    let y: Int
    let height: Int
}

/// JTV tvOS 1.3.3 — gutter-snapped page planning (L-T27 /
/// FL-412, owner-approved method A′; spec:
/// RESEARCH-SAYHENTAI-READING-2026-11-22.md §6).
///
/// The 1.3.2 reader cut every strip at fixed screen-ratio
/// offsets with zero content analysis, so the blade landed
/// mid-panel and mid-speech-bubble (owner's device verdict:
/// "Cách cắt trang của sayhentai không sài được"). This planner
/// changes ONLY where the cuts land; the reader's page-turn
/// frame (discrete turns, Trang X/Y, chapter chaining) is
/// untouched.
///
/// Scoping is by per-image DATA SHAPE, never by plugin name
/// (research §7):
/// • height ≤ one screen → one page, the whole image.
/// • a DISCRETE image (height < 3 screens — the misskon
///   shape: measured 1024×1536 = 2.7 screens at full width)
///   → one page, the whole image, kept as a single unit.
/// • a TALL STRIP (height ≥ 3 screens — the sayhentai shape:
///   measured 8.6–49 screens) → gutter-snapped packing:
///   detect near-uniform horizontal bands (panel gutters),
///   pack whole inter-gutter segments greedily into pages of
///   at most one screen height; a segment that ALONE exceeds
///   a screen is sub-cut inside itself (weakest local gutter
///   first, fixed cut as the last resort); if no gutter is
///   found at all, the plan degrades to exactly the 1.3.2
///   fixed-cut geometry — never worse than the status quo.
///
/// Thresholds are the research's measured working point (§2/§6):
/// rows are sampled on a grayscale copy at most 200 px wide;
/// a row is a STRICT gutter row when its standard deviation
/// is < 7 and ≥ 97% of its pixels lie within ±10 of the row
/// median (black and white gutters both qualify — the test is
/// uniformity, not brightness); a WEAK gutter row relaxes to
/// std < 14 and ≥ 93% within ±16. A strict band is a run of
/// ≥ 6 strict rows, a weak band ≥ 4 weak rows. Segments
/// shorter than 48 px (lettering gaps inside a panel, research
/// §2.3) NEVER stand alone as a page: a post-pass merges any
/// sub-floor page into its neighbour (the previous page, or
/// the next one when it is the first) — unconditionally, per
/// §6 ("không bao giờ đứng một mình — luôn gộp với đoạn kề");
/// the merged crop may exceed one screen height and simply
/// renders aspect-fit, whole, like a discrete image.
///
/// 1.3.4 (L-T29 / FL-443, DIAG-SAYHENTAI-133 §3): the 1.3.3
/// plan still produced SLIVER pages — the remainder of a
/// panel just over one screen tall (panel ≈ segH + 70…140 px)
/// stood alone at 0.2–0.3 × segH, because the sub-cut's fixed
/// fallback left that remainder unsized and the post-pass
/// floor was a flat 48 px. Two rules close the class:
/// R1 — when an over-tall segment's LAST piece (the
/// remainder) is under half a screen, the segment's last two
/// pieces are re-split at their pair midpoint (snapped to
/// the weakest weak gutter within ±segH/8 when one qualifies),
/// so every resulting piece lies in [3·segH/8, segH]; a pair
/// with no legal split merges into one piece instead (or,
/// when its span exceeds one screen, is left unsplit for
/// R2's page-level merge — never an over-screen piece).
/// R2 — the post-pass page floor is proportional:
/// max(48, ⌈segH/2⌉). No page under half a screen ever
/// stands alone (a strip's single page excepted). The 48 px
/// constant keeps its original job at the SEGMENT layer
/// (lettering-gap noise, research §2.3) and as the sub-cut's
/// minimum first piece; R2 changes only the PAGE floor.
///
/// Cost: one pass over a ≤200-px-wide grayscale copy —
/// measured ≈0.1 s per strip on the shared VM for the
/// reference implementation (research §4A′); it runs once per
/// strip at decode time inside the reader's existing load
/// tasks, never in the view body.
enum TVMangaPagePlanner {

    // MARK: Working point (research §6)

    private static let scanWidthCap = 200
    private static let strictStdMax = 7.0
    private static let strictWithinBand = 10
    private static let strictWithinFraction = 0.97
    private static let weakStdMax = 14.0
    private static let weakWithinBand = 16
    private static let weakWithinFraction = 0.93
    private static let strictBandMinRows = 6
    private static let weakBandMinRows = 4
    private static let microSegmentFloor = 48
    /// An image at least this many screens tall is a strip;
    /// below it, a discrete page image (measured gap between
    /// the two shapes: misskon 2.7 screens vs sayhentai 8.6).
    private static let stripScreenMultiple = 3

    // MARK: Plan

    static func plan(cgImage cg: CGImage, segmentHeight segH: Int) -> [TVMangaPageRect] {
        let height = cg.height
        guard segH > 0, height > 0 else {
            return [TVMangaPageRect(y: 0, height: max(1, height))]
        }
        if height <= segH {
            return [TVMangaPageRect(y: 0, height: height)]
        }
        // Discrete image — one unit, whole (the misskon shape).
        if height < stripScreenMultiple * segH {
            return [TVMangaPageRect(y: 0, height: height)]
        }
        let (strictBands, weakBands) = gutterBands(of: cg)
        guard !strictBands.isEmpty else {
            // Detection failure degrades to the 1.3.2 geometry.
            return mergeMicroPages(fixedPlan(height: height, segmentHeight: segH),
                                   segmentHeight: segH)
        }
        // Content segments: the runs between strict bands.
        var segments: [(start: Int, end: Int)] = []
        var cursor = 0
        for band in strictBands {
            if band.start > cursor { segments.append((cursor, band.start)) }
            cursor = max(cursor, band.end)
        }
        if cursor < height { segments.append((cursor, height)) }
        guard segments.count > 1 else {
            return mergeMicroPages(fixedPlan(height: height, segmentHeight: segH),
                                   segmentHeight: segH)
        }
        // Split over-tall segments first (weakest local gutter
        // inside the screen window, else a fixed cut), so the
        // packing pass below only ever sees screen-fitting
        // pieces.
        var pieces: [(start: Int, end: Int)] = []
        for segment in segments {
            guard segment.end - segment.start > segH else {
                pieces.append(segment)
                continue
            }
            var segPieces: [(start: Int, end: Int)] = []
            var y = segment.start
            while segment.end - y > segH {
                let limit = y + segH
                // §6: the sub-cut lands at the WEAKEST weak
                // gutter inside the window — the band whose
                // rows are least uniform (highest worst-row
                // std) while still qualifying as a weak band;
                // ties go to the deepest band. The piece ends
                // at the band's START (≤ limit, so the piece
                // never exceeds one screen height) and reading
                // resumes at the band's END: the near-uniform
                // band rows themselves are gutter, shown on no
                // page.
                var cutEnd: Int?
                var resumeY = limit
                var weakestStrength = -1.0
                for band in weakBands
                where band.start > y + microSegmentFloor && band.start <= limit {
                    if band.strength > weakestStrength
                        || (band.strength == weakestStrength
                            && (cutEnd == nil || band.start > cutEnd!)) {
                        weakestStrength = band.strength
                        cutEnd = band.start
                        resumeY = band.end
                    }
                }
                if let cutEnd {
                    segPieces.append((y, cutEnd))
                    y = resumeY
                } else {
                    segPieces.append((y, limit))
                    y = limit
                }
            }
            if segment.end > y { segPieces.append((y, segment.end)) }
            // R1 (L-T29): a sub-half-screen remainder never
            // leaves the sub-cut — the segment's last two
            // pieces are rebalanced before packing.
            pieces.append(contentsOf: rebalanced(segPieces,
                                                 weakBands: weakBands,
                                                 segH: segH))
        }
        // Greedy packing: accumulate whole pieces while the
        // crop (first piece's start → last piece's end, the
        // thin gutters between them included) fits one screen.
        var rects: [TVMangaPageRect] = []
        var i = 0
        while i < pieces.count {
            let start = pieces[i].start
            var j = i
            while j + 1 < pieces.count, pieces[j + 1].end - start <= segH {
                j += 1
            }
            rects.append(TVMangaPageRect(y: start, height: pieces[j].end - start))
            i = j + 1
        }
        return rects.isEmpty
            ? mergeMicroPages(fixedPlan(height: height, segmentHeight: segH),
                              segmentHeight: segH)
            : mergeMicroPages(rects, segmentHeight: segH)
    }

    /// R1 (1.3.4, L-T29 / FL-443; DIAG-SAYHENTAI-133 §3): the
    /// remainder rebalance. When an over-tall segment's LAST
    /// piece is shorter than half a screen (`lastHeight * 2 <
    /// segH`), the segment's last two pieces are re-split at
    /// their pair midpoint: the cut snaps to the WEAKEST weak
    /// gutter within ±segH/8 of the midpoint when a band
    /// qualifies (band start past the 48 px floor, and BOTH
    /// resulting pieces ≥ 3·segH/8 — the snap follows the
    /// sub-cut's own convention: the piece ends at the band's
    /// start and reading resumes at its end, the band rows
    /// shown on no page); with no qualifying band the cut is
    /// fixed at the midpoint.
    ///
    /// Gate 1.3.4 Round 1 (Lens A) hardening: every split is
    /// validated on the heights it ACTUALLY emits, never on
    /// the pair's raw span. The span (pairEnd − pairStart)
    /// includes any weak band the sub-cut ate between the two
    /// pieces; with a band ≳ segH/2 the span passes 2·segH
    /// and an unguarded span-midpoint split emitted pieces
    /// TALLER than one screen (lens reproduction: span 1505
    /// at segH 405 → 752/753 px pieces), breaking §4.3's
    /// interval [3·segH/8, segH]. So now: a snap candidate
    /// must satisfy BOTH bounds on both emitted heights (the
    /// first piece ends at the band's start, the second
    /// resumes at its end — the eaten band is in neither);
    /// the fixed cut is taken only at a point whose two
    /// emitted heights both lie in [3·segH/8, segH] (the
    /// legal cut points form a contiguous interval that
    /// contains the midpoint whenever it is non-empty, so
    /// clamping the midpoint into it is exact); and when NO
    /// legal split exists the pair is not split at all —
    /// it merges into one piece when the span fits a screen
    /// (the too-small pair), and when the span itself
    /// exceeds a screen (a giant eaten band) the two pieces
    /// are left exactly as the sub-cut made them — each
    /// already ≤ segH — for R2 to merge at page level,
    /// which yields the same aspect-fit page a piece-level
    /// merge would, without manufacturing an over-screen
    /// piece. Every other piece, every gutter cut and the
    /// packing pass are untouched: R1 fires only on the
    /// convicted remainder shape.
    private static func rebalanced(
        _ segPieces: [(start: Int, end: Int)],
        weakBands: [(start: Int, end: Int, strength: Double)],
        segH: Int
    ) -> [(start: Int, end: Int)] {
        guard segPieces.count >= 2, segH > 0 else { return segPieces }
        let last = segPieces[segPieces.count - 1]
        let prev = segPieces[segPieces.count - 2]
        guard (last.end - last.start) * 2 < segH else { return segPieces }
        let pairStart = prev.start
        let pairEnd = last.end
        let span = pairEnd - pairStart
        // The R1 floor as a height: a piece of height h is a
        // legal split product iff h * 8 >= 3 * segH
        // (integer-exact, the same test the snap used before).
        let minPiece = (3 * segH + 7) / 8
        var result = Array(segPieces.dropLast(2))
        // Snap split: the weakest weak gutter within ±segH/8
        // of the pair midpoint whose two EMITTED pieces both
        // lie in [minPiece, segH].
        let mid = pairStart + span / 2
        let window = segH / 8
        var chosen: (start: Int, end: Int)?
        var weakestStrength = -1.0
        for band in weakBands
        where band.start >= mid - window && band.start <= mid + window
            && band.start - pairStart > microSegmentFloor
            && band.start - pairStart >= minPiece
            && band.start - pairStart <= segH
            && pairEnd - band.end >= minPiece
            && pairEnd - band.end <= segH {
            if band.strength > weakestStrength
                || (band.strength == weakestStrength
                    && (chosen == nil || band.start > chosen!.start)) {
                weakestStrength = band.strength
                chosen = (band.start, band.end)
            }
        }
        if let chosen {
            result.append((pairStart, chosen.start))
            result.append((chosen.end, pairEnd))
            return result
        }
        // Fixed split: taken only where both emitted heights
        // are legal (see the doc comment for why clamping
        // the midpoint into the legal interval is exact).
        let cutLo = max(pairStart + minPiece, pairEnd - segH)
        let cutHi = min(pairEnd - minPiece, pairStart + segH)
        if cutLo <= cutHi {
            let cut = min(max(mid, cutLo), cutHi)
            result.append((pairStart, cut))
            result.append((cut, pairEnd))
            return result
        }
        // No legal split exists: merge the pair into one
        // piece when the merged span fits a screen; with an
        // over-screen span, leave the pair unsplit for R2's
        // page-level merge.
        if span <= segH {
            result.append((pairStart, pairEnd))
        } else {
            result.append(prev)
            result.append(last)
        }
        return result
    }

    /// §6's micro-segment rule, applied as a post-pass over
    /// every strip plan (gutter-packed and fixed alike): a
    /// page shorter than the floor NEVER stands alone — it
    /// merges into the previous page (or the next one when
    /// it is the first page), the merged crop spanning from
    /// the keeper's start to the micro page's end, gutter rows
    /// between them included. Unconditional: the merged crop
    /// may exceed one screen height and renders aspect-fit,
    /// whole. Repeats until no micro page remains (a merge
    /// can itself follow a micro page).
    ///
    /// 1.3.4 (R2, L-T29 / FL-443): the floor is no longer the
    /// flat 48 px — that constant was born for SEGMENT noise
    /// (lettering gaps, research §2.3) and let 70–140 px
    /// sliver pages (0.2–0.3 × segH) through untouched. The
    /// PAGE floor is now max(48, ⌈segH/2⌉): no page under
    /// half a screen stands alone, on the gutter-packed path
    /// and on the fixed fallback alike. A strip reduced to a
    /// single page keeps it (the loop's count > 1 guard).
    static func mergeMicroPages(_ rects: [TVMangaPageRect],
                                segmentHeight segH: Int) -> [TVMangaPageRect] {
        let floor = max(microSegmentFloor, (segH + 1) / 2)
        var rects = rects
        var changed = true
        while changed, rects.count > 1 {
            changed = false
            for i in rects.indices where rects[i].height < floor {
                if i > 0 {
                    let prev = rects[i - 1]
                    let cur = rects[i]
                    rects[i - 1] = TVMangaPageRect(
                        y: prev.y, height: (cur.y + cur.height) - prev.y)
                    rects.remove(at: i)
                } else {
                    let cur = rects[0]
                    let next = rects[1]
                    rects[0] = TVMangaPageRect(
                        y: cur.y, height: (next.y + next.height) - cur.y)
                    rects.remove(at: 1)
                }
                changed = true
                break
            }
        }
        return rects
    }

    /// The 1.3.2 geometry verbatim: cuts at fixed multiples of
    /// the segment height. The degradation floor of every
    /// failure path above.
    static func fixedPlan(height: Int, segmentHeight segH: Int) -> [TVMangaPageRect] {
        guard segH > 0, height > 0 else {
            return [TVMangaPageRect(y: 0, height: max(1, height))]
        }
        var rects: [TVMangaPageRect] = []
        var y = 0
        while y < height {
            let h = min(segH, height - y)
            rects.append(TVMangaPageRect(y: y, height: h))
            y += h
        }
        return rects
    }

    // MARK: Gutter scan

    /// Strict and weak gutter bands of the image, as
    /// (start, end, strength) in top-origin pixel space,
    /// ascending. Strength is the band's WORST (highest)
    /// row standard deviation — the sub-cut's weakest-gutter
    /// ranking (§6) compares it across weak bands. The scan
    /// draws the image into a grayscale context at most
    /// `scanWidthCap` px wide and the FULL height (rows are
    /// never resampled vertically, so band positions are
    /// exact image rows). The context is flipped so buffer
    /// row 0 is the image's TOP row — the same top-origin
    /// space CGImage.cropping uses.
    private static func gutterBands(of cg: CGImage)
        -> (strict: [(start: Int, end: Int, strength: Double)],
            weak: [(start: Int, end: Int, strength: Double)]) {
        let width = min(cg.width, scanWidthCap)
        let height = cg.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let base = context.data else {
            return ([], [])
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = base.bindMemory(to: UInt8.self, capacity: width * height)

        var strictRows = [Bool](repeating: false, count: height)
        var weakRows = [Bool](repeating: false, count: height)
        var rowStd = [Double](repeating: 0, count: height)
        var histogram = [Int](repeating: 0, count: 256)
        for row in 0..<height {
            for i in histogram.indices { histogram[i] = 0 }
            let offset = row * width
            var sum = 0
            for x in 0..<width {
                let v = Int(bytes[offset + x])
                histogram[v] += 1
                sum += v
            }
            let mean = Double(sum) / Double(width)
            var cumulative = 0
            var median = 0
            for v in 0..<256 {
                cumulative += histogram[v]
                if cumulative * 2 >= width { median = v; break }
            }
            var squared = 0.0
            for v in 0..<256 where histogram[v] > 0 {
                let d = Double(v) - mean
                squared += d * d * Double(histogram[v])
            }
            let std = (squared / Double(width)).squareRoot()
            rowStd[row] = std
            if std < strictStdMax {
                var within = 0
                let lo = max(0, median - strictWithinBand)
                let hi = min(255, median + strictWithinBand)
                for v in lo...hi { within += histogram[v] }
                strictRows[row] = Double(within) >= strictWithinFraction * Double(width)
            }
            if std < weakStdMax {
                var within = 0
                let lo = max(0, median - weakWithinBand)
                let hi = min(255, median + weakWithinBand)
                for v in lo...hi { within += histogram[v] }
                weakRows[row] = Double(within) >= weakWithinFraction * Double(width)
            }
        }
        return (bands(from: strictRows, stds: rowStd, minRows: strictBandMinRows),
                bands(from: weakRows, stds: rowStd, minRows: weakBandMinRows))
    }

    /// Maximal runs of `true` rows at least `minRows` long, as
    /// (start, end, strength) with end exclusive, ascending;
    /// strength = the highest row std inside the run.
    private static func bands(from rows: [Bool], stds: [Double], minRows: Int)
        -> [(start: Int, end: Int, strength: Double)] {
        var result: [(start: Int, end: Int, strength: Double)] = []
        var runStart: Int?
        func closeRun(end: Int) {
            guard let start = runStart, end - start >= minRows else { return }
            var strength = 0.0
            for row in start..<end where stds[row] > strength {
                strength = stds[row]
            }
            result.append((start, end, strength))
        }
        for (index, flag) in rows.enumerated() {
            if flag {
                if runStart == nil { runStart = index }
            } else if runStart != nil {
                closeRun(end: index)
                runStart = nil
            }
        }
        if runStart != nil { closeRun(end: rows.count) }
        return result
    }
}
