import Foundation
import XCTest

/// Contract test that pins every `.onGeometryChange(for:of:action:)` call site
/// in the macOS app to a documented allowlist.
///
/// Geometry callbacks fire on every layout pass. If a callback writes back into
/// `@AppStorage`, `@SceneStorage`, or any store that participates in the next
/// invalidation cycle, the write itself drives another layout pass, which
/// drives another write. The loop sustains itself at frame rate and burns the
/// main thread until something else changes.
///
/// Locking the call sites means every new placement has to be a deliberate,
/// documented decision: either the write is thresholded (writes only when the
/// computed value crosses a stable boundary), deferred to a later main-actor
/// turn, or kept inside ephemeral view-local `@State` that does not invalidate
/// ancestor stores. Anyone adding a new site has to update the allowlist with
/// a rationale, which forces the perf review to happen at edit time, not
/// during a hitch hunt.
final class GeometryWritebackContractTests: XCTestCase {
    /// Permitted hosts and the exact count of `.onGeometryChange(` invocations
    /// expected in each file. Every entry has a comment explaining why this
    /// site is safe.
    ///
    /// To add a new site, append the file with its expected count and a
    /// rationale that covers either thresholding, deferred writeback, or pure
    /// ephemeral-`@State` scope. To remove a site, drop the entry. To change
    /// the count for an existing entry, restate the rationale (the new use is
    /// not automatically protected by the old one).
    private static let allowlist: [GeometryWritebackAllowance] = [
        // Settings notifications form mirrors the Title-field width to the
        // Body-field width so the multi-line body lines up with single-line
        // fields. Writes go into a view-local `@State` (`contentFieldWidth`)
        // that is consumed via `.frame(width:)` on the same form section.
        // SwiftUI coalesces equal-value updates; the value is bounded by the
        // window width and stops moving once the form settles.
        .init(
            relativePath: "Sources/HarnessMonitorUIPreviewable/Views/Settings/SettingsNotificationsSection.swift",
            expectedCount: 1,
            rationale: "ephemeral @State width mirror inside the settings form"
        ),
        // Agent-detail send-update presentation flips a boolean
        // `fitsHorizontally` threshold based on whether the status row clears
        // a minimum width. The action body is gated by `!= next` so writes
        // only happen on the actual transition; the bool drives a deterministic
        // if/else, replacing the implicit `ViewThatFits` feedback loop with an
        // explicit measured layout.
        .init(
            relativePath: "Sources/HarnessMonitorUIPreviewable/Views/Agents/AgentDetailSendUpdateSection+Presentation.swift",
            expectedCount: 1,
            rationale: "threshold-gated horizontal-fit flag for status row"
        ),
        // Same threshold-gated `fitsHorizontally` pattern as the presentation
        // file: drives the composer's wide-vs-stacked layout. Write is gated
        // on transition, so the callback stops re-firing as soon as the form
        // stabilises around its measured width.
        .init(
            relativePath: "Sources/HarnessMonitorUIPreviewable/Views/Agents/AgentDetailSendUpdateSection.swift",
            expectedCount: 1,
            rationale: "threshold-gated horizontal-fit flag for send-update composer"
        ),
        // Two threshold-gated `fitsHorizontally` flags drive the runtime-lane
        // band and the action band's wide/stacked layouts. Each callback only
        // writes when the boolean would actually change, replacing nested
        // `ViewThatFits` with measured `if/else`.
        .init(
            relativePath: "Sources/HarnessMonitorUIPreviewable/Views/Agents/AgentDetailSectionBands.swift",
            expectedCount: 2,
            rationale: "two threshold-gated horizontal-fit flags for agent-detail bands"
        ),
        // Session agent lane mirrors the visible TUI viewport size to the
        // PTY-resize side car via a `Task { @MainActor in await syncTerminalSize }`.
        // The handler hops off the layout pass before it touches the terminal,
        // and `resizeState.cancelPending()` debounces repeats in flight, so
        // the geometry callback itself never writes back into a store that
        // would re-invalidate the lane on the next frame.
        .init(
            relativePath: "Sources/HarnessMonitorUIPreviewable/Views/Sessions/SessionAgentLaneViews.swift",
            expectedCount: 1,
            rationale: "async-task PTY resize off the layout pass with cancel-pending debounce"
        ),
        // Timeline section records the measured container height so the
        // dynamic page size can size paging requests to the visible window.
        // The handler only updates `measuredContainerHeight` when the height
        // crosses an integer-rounded threshold (see
        // `updateMeasuredContainerHeight`), so the writeback is bounded.
        .init(
            relativePath: "Sources/HarnessMonitorUIPreviewable/Views/Timeline/MonitorTimelineSection.swift",
            expectedCount: 1,
            rationale: "rounded-height threshold drives dynamic timeline page size"
        ),
        // Task board overview uses one width threshold to choose compact vs
        // horizontal layout. The handler writes a view-local boolean only when
        // the threshold result changes.
        .init(
            relativePath: "Sources/HarnessMonitorUIPreviewable/Views/TaskBoard/TaskBoardOverviewView.swift",
            expectedCount: 1,
            rationale: "threshold-gated view-local width flag for task-board overview"
        ),
        // Orchestrator summary uses one explicit width gate. The write is a
        // view-local boolean guarded by `!= next`.
        .init(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/TaskBoard/TaskBoardOrchestratorSummaryView.swift",
            expectedCount: 1,
            rationale: "threshold-gated view-local width flag for orchestrator summary"
        ),
    ]

    func testEveryOnGeometryChangeSiteIsAllowlisted() throws {
        let sources = try collectOnGeometryChangeSites()
        XCTAssertFalse(
            sources.isEmpty,
            "Walker found no `.onGeometryChange(` sites; scanner is likely broken."
        )

        let allowedPaths = Set(Self.allowlist.map(\.relativePath))
        let foundPaths = Set(sources.map(\.relativePath))

        let extraPaths = foundPaths.subtracting(allowedPaths).sorted()
        XCTAssertTrue(
            extraPaths.isEmpty,
            """
            Found `.onGeometryChange(` in files outside the allowlist.

            Adding a new geometry callback is a perf-sensitive choice: the action
            fires on every layout pass. Either remove the call, or add the file
            to `GeometryWritebackContractTests.allowlist` with a rationale that
            explains why the writeback is safe (thresholded, deferred to the
            next main-actor turn, or scoped to ephemeral view-local @State).

            New sites:
            \(extraPaths.joined(separator: "\n"))
            """
        )
    }

    func testEveryOnGeometryChangeSiteMatchesAllowlistedCount() throws {
        let sources = try collectOnGeometryChangeSites()
        let countsByPath = Dictionary(grouping: sources, by: \.relativePath)
            .mapValues(\.count)

        var mismatches: [String] = []
        for allowance in Self.allowlist {
            let actual = countsByPath[allowance.relativePath] ?? 0
            if actual != allowance.expectedCount {
                mismatches.append(
                    "  \(allowance.relativePath): expected \(allowance.expectedCount), found \(actual)"
                )
            }
        }

        XCTAssertTrue(
            mismatches.isEmpty,
            """
            One or more allowlisted files have a different number of \
            `.onGeometryChange(` call sites than the allowlist documents. \
            Either revert the new call (and explain why this hurts), or update \
            the allowlist entry's `expectedCount` and refresh the rationale.

            Mismatches:
            \(mismatches.joined(separator: "\n"))
            """
        )
    }

    func testAllowlistHasNoStaleEntries() throws {
        let sources = try collectOnGeometryChangeSites()
        let foundPaths = Set(sources.map(\.relativePath))
        let stalePaths = Self.allowlist
            .map(\.relativePath)
            .filter { !foundPaths.contains($0) }
            .sorted()

        XCTAssertTrue(
            stalePaths.isEmpty,
            """
            One or more allowlist entries point at files that no longer contain \
            `.onGeometryChange(`. Drop the entry from \
            `GeometryWritebackContractTests.allowlist` to keep the rationale \
            list honest.

            Stale entries:
            \(stalePaths.joined(separator: "\n"))
            """
        )
    }

    // MARK: - Scanner

    private struct GeometryWritebackAllowance {
        let relativePath: String
        let expectedCount: Int
        let rationale: String
    }

    private struct GeometryWritebackSite {
        let relativePath: String
        let line: Int
    }

    private func collectOnGeometryChangeSites() throws -> [GeometryWritebackSite] {
        let sourcesRoot = appRootURL.appendingPathComponent("Sources")
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: sourcesRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            XCTFail("Failed to enumerate \(sourcesRoot.path)")
            return []
        }

        let pattern = #"\.onGeometryChange\("#
        let regex = try NSRegularExpression(pattern: pattern)
        var sites: [GeometryWritebackSite] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let relativePath = relativePath(for: fileURL)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, range: range) {
                guard let matchRange = Range(match.range, in: source) else { continue }
                let line = lineNumber(of: matchRange.lowerBound, in: source)
                sites.append(
                    GeometryWritebackSite(relativePath: relativePath, line: line)
                )
            }
        }
        sites.sort { lhs, rhs in
            if lhs.relativePath != rhs.relativePath {
                return lhs.relativePath < rhs.relativePath
            }
            return lhs.line < rhs.line
        }
        return sites
    }

    private func lineNumber(of index: String.Index, in source: String) -> Int {
        var line = 1
        var cursor = source.startIndex
        while cursor < index {
            if source[cursor] == "\n" {
                line += 1
            }
            cursor = source.index(after: cursor)
        }
        return line
    }

    private func relativePath(for fileURL: URL) -> String {
        let prefix = appRootURL.path + "/"
        let path = fileURL.path
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    private var appRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
