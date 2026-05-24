import Foundation
import XCTest

/// Contract test that pins every `.dropDestination(...)` call site in the
/// macOS app to a documented allowlist.
///
/// A drop handler that returns `false` without surfacing the rejection — no
/// overlay update, no `store.reportDropRejection(...)`, no view-model state
/// flip — looks identical to a successful drop that was eaten by the OS. The
/// user drags an item onto a target that visually accepts the drag (the lane
/// chrome lights up, the agent card glows), releases, and nothing happens.
/// That class of bug is hard to spot in review because every individual
/// `return false` reads as defensive.
///
/// Locking the call sites turns every new drop handler into a deliberate,
/// documented choice. Each allowlist entry has to state how rejection is made
/// visible to the user: an explicit feedback call, a view-model state flip
/// that drives an overlay, or — when the rejection is a defensive guard that
/// should never fire in practice — that rationale is written down so a future
/// reviewer can challenge it.
final class DropDestinationContractTests: XCTestCase {
    /// Permitted hosts and the exact count of `.dropDestination(` invocations
    /// expected in each file. Every entry has a comment explaining how the
    /// rejection-feedback story works for that handler.
    ///
    /// To add a new site, append the file with its expected count and a
    /// rationale that covers either an explicit user-visible rejection call,
    /// a view-model-delegated rejection state, or a defensive guard that
    /// would only fire on a runtime-impossible code path. To remove a site,
    /// drop the entry. To change the count for an existing entry, restate
    /// the rationale — the new handler is not automatically protected by the
    /// old one.
    private static let allowlist: [DropDestinationAllowance] = [
        // TaskBoard lane column has two drop handlers, one for API items and
        // one for inbox items. Both delegate to TaskBoardLaneDropPolicy /
        // TaskBoardInboxDropPolicy via performAPIDrop / performInboxDrop,
        // which route through TaskBoardDropDeduper. The only `return false`
        // path in handleAPIDrop / handleInboxDrop is the empty-payloads
        // defensive guard (no payload means SwiftUI delivered an empty
        // session, which the type system makes runtime-impossible for the
        // typed payload variants). In-flight feedback flows through
        // taskBoardLaneBodyChrome(isDropTargeted:) and the dedup-aware
        // updateAPIDropTargeted / updateInboxDropTargeted callbacks.
        .init(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/TaskBoard/TaskBoardLaneUnifiedColumn.swift",
            expectedCount: 2,
            rationale: "delegated to drop-policy + deduper; empty-payload guard is defensive"
        ),
        // SessionAgentSummaryCard's task-drop handler is the canonical
        // user-visible rejection pattern: every `return false` is paired
        // with `store.reportDropRejection(...)` carrying a specific reason
        // ("no task payload", "drag source does not belong to this session",
        // or the disabled-reason from `taskDropAction.feedback.accessibilityLabel`).
        // The card also renders an AgentTaskDropFeedbackOverlay driven by
        // `taskDropAction.feedback`, plus a DropTargetPulseBorder while a
        // task drag is in flight.
        .init(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/Sessions/SessionAgentSummaryCard.swift",
            expectedCount: 1,
            rationale: "every return-false paired with store.reportDropRejection + overlay feedback"
        ),
        // PolicyCanvas port-to-port edge drop. Delegates to
        // viewModel.connectDroppedPortPayloads(_:targetNodeID:targetPortID:targetSide:);
        // pending-edge preview is cleared in the companion DragGesture.onEnded,
        // and the `isTargeted` callback flips viewModel.setInputTargeted to
        // drive the port's hover/accept chrome. Connection rejection (wrong
        // direction, self-loop, duplicate edge) is owned by the view model
        // and reflected in the pending-edge preview state before commit.
        .init(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/PolicyCanvas/PolicyCanvasPortViews.swift",
            expectedCount: 1,
            rationale: "delegated to viewModel.connectDroppedPortPayloads; setInputTargeted drives chrome"
        ),
        // PolicyCanvas group-region drop. Delegates to
        // viewModel.dropPalettePayloadsOnGroup(_:groupID:at:); the
        // `isTargeted` callback flips viewModel.setGroupDropTargeted, which
        // drives the group's targeted-state outline. Accepted drops trigger
        // the Wave 4K acceptance-flash via groupAcceptanceFlashID inside the
        // view model.
        .init(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/PolicyCanvas/PolicyCanvasGroupViews.swift",
            expectedCount: 1,
            rationale: "delegated to viewModel.dropPalettePayloadsOnGroup; setGroupDropTargeted drives chrome"
        ),
        // PolicyCanvas root drop (drops onto blank canvas). Delegates to
        // viewModel.dropPalettePayloads(_:at:); the workspace's user-visible
        // signals are the PolicyCanvasEmptyStatePlaceholder overlay (cleared
        // on first node placement) and the canvas hover state. The view
        // model already owns drop-acceptance gating; this drop handler only
        // forwards the payload list and the canvas-space location.
        .init(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift",
            expectedCount: 1,
            rationale: "delegated to viewModel.dropPalettePayloads; canvas overlays carry feedback"
        ),
    ]

    func testEveryDropDestinationSiteIsAllowlisted() throws {
        let sources = try collectDropDestinationSites()
        XCTAssertFalse(
            sources.isEmpty,
            "Walker found no `.dropDestination(` sites; scanner is likely broken."
        )

        let allowedPaths = Set(Self.allowlist.map(\.relativePath))
        let foundPaths = Set(sources.map(\.relativePath))

        let extraPaths = foundPaths.subtracting(allowedPaths).sorted()
        XCTAssertTrue(
            extraPaths.isEmpty,
            """
            Found `.dropDestination(` in files outside the allowlist.

            A drop handler that returns `false` without telling the user is
            indistinguishable from a successful drop. Either route rejection
            through `store.reportDropRejection(...)` (or an equivalent
            user-visible feedback call), delegate to a view-model method that
            owns the rejection state, or — if the rejection is a defensive
            guard that should never fire — add the file to
            `DropDestinationContractTests.allowlist` with a rationale that
            explains why no user-visible signal is required.

            New sites:
            \(extraPaths.joined(separator: "\n"))
            """
        )
    }

    func testEveryDropDestinationSiteMatchesAllowlistedCount() throws {
        let sources = try collectDropDestinationSites()
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
            `.dropDestination(` call sites than the allowlist documents. \
            Either revert the new call (and explain why it hurts), or update \
            the allowlist entry's `expectedCount` and refresh the rationale.

            Mismatches:
            \(mismatches.joined(separator: "\n"))
            """
        )
    }

    func testAllowlistHasNoStaleEntries() throws {
        let sources = try collectDropDestinationSites()
        let foundPaths = Set(sources.map(\.relativePath))
        let stalePaths = Self.allowlist
            .map(\.relativePath)
            .filter { !foundPaths.contains($0) }
            .sorted()

        XCTAssertTrue(
            stalePaths.isEmpty,
            """
            One or more allowlist entries point at files that no longer \
            contain `.dropDestination(`. Drop the entry from \
            `DropDestinationContractTests.allowlist` to keep the rationale \
            list honest.

            Stale entries:
            \(stalePaths.joined(separator: "\n"))
            """
        )
    }

    // MARK: - Scanner

    private struct DropDestinationAllowance {
        let relativePath: String
        let expectedCount: Int
        let rationale: String
    }

    private struct DropDestinationSite {
        let relativePath: String
        let line: Int
    }

    private func collectDropDestinationSites() throws -> [DropDestinationSite] {
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

        let pattern = #"\.dropDestination\("#
        let regex = try NSRegularExpression(pattern: pattern)
        var sites: [DropDestinationSite] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let stripped = sourceWithCommentsStripped(source)
            let relativePath = relativePath(for: fileURL)
            let range = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
            for match in regex.matches(in: stripped, range: range) {
                guard let matchRange = Range(match.range, in: stripped) else { continue }
                let line = lineNumber(of: matchRange.lowerBound, in: stripped)
                sites.append(
                    DropDestinationSite(relativePath: relativePath, line: line)
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

    /// Replaces every `//` line comment and `/* ... */` block comment with
    /// spaces so the regex above does not match a documented reference to
    /// `.dropDestination(` (for example, a "see also" comment in
    /// PolicyCanvasWorkspaceViews.swift). Newlines are preserved so line
    /// numbers report correctly. String literals are kept intact, so a
    /// `"// foo"` substring is not mistaken for a comment.
    private func sourceWithCommentsStripped(_ source: String) -> String {
        var output = ""
        output.reserveCapacity(source.count)
        var index = source.startIndex

        func peek() -> Character? {
            guard index < source.endIndex else { return nil }
            return source[index]
        }
        func advance() -> Character? {
            guard index < source.endIndex else { return nil }
            let character = source[index]
            index = source.index(after: index)
            return character
        }

        while let character = advance() {
            switch character {
            case "/":
                if peek() == "/" {
                    _ = advance()
                    while let next = peek(), next != "\n" {
                        _ = advance()
                        output.append(" ")
                    }
                    output.append("  ")
                } else if peek() == "*" {
                    _ = advance()
                    output.append("  ")
                    while let next = advance() {
                        if next == "\n" {
                            output.append("\n")
                            continue
                        }
                        if next == "*" && peek() == "/" {
                            _ = advance()
                            output.append("  ")
                            break
                        }
                        output.append(" ")
                    }
                } else {
                    output.append(character)
                }
            case "\"":
                output.append(character)
                while let next = advance() {
                    output.append(next)
                    if next == "\\" {
                        if let escaped = advance() {
                            output.append(escaped)
                        }
                        continue
                    }
                    if next == "\"" { break }
                }
            default:
                output.append(character)
            }
        }
        return output
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
