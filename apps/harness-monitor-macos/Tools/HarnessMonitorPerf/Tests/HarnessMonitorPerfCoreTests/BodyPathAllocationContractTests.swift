import Foundation
import XCTest

/// Pins a perf-sensitive rule for the SwiftUI view layer: heavyweight Foundation
/// formatter/encoder objects must not be allocated inline inside files under
/// `apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/`.
///
/// Allocating any of these inside `body`, computed view properties, or per-row
/// helpers is expensive enough to show up as per-frame work in Instruments.
/// Module-scope or type-scope `static let` / `@MainActor private let` IIFE
/// caches (see `Theme/HarnessMonitorFormatters.swift` for the canonical
/// pattern) are the correct home.
///
/// The scanner walks every `.swift` file under `Views/`, regex-matches each
/// constructor site, and accepts a site only if the line itself or one of the
/// three preceding lines opens a cached `let` binding (module or type scope).
/// Anything else fails — unless it appears verbatim in `knownAcceptedSites`
/// with a documented rationale. Sites in that allowlist must still exist; a
/// stale entry also fails so cleanup work cannot drift.
final class BodyPathAllocationContractTests: XCTestCase {
    /// Foundation types whose default constructors must never appear in a
    /// body-path / computed-property allocation. Listed explicitly (rather
    /// than a wildcard) so each entry is a deliberate addition.
    private static let bannedTypes: [String] = [
        "DateFormatter",
        "NumberFormatter",
        "ByteCountFormatter",
        "RelativeDateTimeFormatter",
        "JSONEncoder",
        "JSONDecoder",
        "PropertyListEncoder",
        "PropertyListDecoder",
        "ISO8601DateFormatter",
        "MeasurementFormatter",
        "PersonNameComponentsFormatter",
    ]

    /// Substrings that mark a `let` binding as a documented static/instance
    /// cache. A match is accepted if the match line itself or any of the
    /// three preceding lines contains any of these tokens. The list captures
    /// every form the codebase uses today; add new variants here with a brief
    /// comment so we keep visibility of the broadening surface.
    private static let acceptedDeclarationPrefixes: [String] = [
        // Module-scope or type-scope static cache.
        "static let ",
        "private static let ",
        "fileprivate static let ",
        "public static let ",
        "internal static let ",
        // Private-instance cache stored on a struct/class.
        "private let ",
        "fileprivate let ",
        // MainActor-isolated module-scope cache, the dominant pattern in
        // HarnessMonitorFormatters.swift and DecisionRow.swift.
        "@MainActor private let ",
        "@MainActor public let ",
        "@MainActor static let ",
        "@MainActor private static let ",
        // `nonisolated(unsafe)` variants used for parsers that must be reachable
        // from background-isolated code (see SessionTimelineNodeBuilder).
        "nonisolated(unsafe) private static let ",
        "nonisolated(unsafe) static let ",
        "nonisolated(unsafe) private let ",
    ]

    /// Documented pre-existing sites that allocate inline but are not on a
    /// per-frame path. Each entry MUST stay current — when the underlying line
    /// number or constructor changes, update or remove the entry. A stale
    /// entry fails the test so this list cannot rot.
    ///
    /// New entries require: (a) a sentence explaining why moving to a static
    /// cache is impractical, and (b) confirmation the call site is NOT in
    /// `body`, a computed view property, or a per-row helper.
    private static let knownAcceptedSites: [KnownSite] = [
        // Drag-and-drop payload encode for `TaskBoardItemDragPayload`. Runs
        // once per drag event from `itemProvider()` — not a render path.
        KnownSite(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/TaskBoard/TaskBoardLaneViews.swift",
            line: 20,
            constructor: "JSONEncoder"
        ),
        // Drop completion handler decoding the same payload. Runs once per
        // drop event from `loadFirst(from:completion:)`.
        KnownSite(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/TaskBoard/TaskBoardLaneViews.swift",
            line: 49,
            constructor: "JSONDecoder"
        ),
        // Drag-and-drop payload encode for `TaskBoardInboxItemDragPayload`.
        // Same one-per-event story as line 20.
        KnownSite(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/TaskBoard/TaskBoardLaneViews.swift",
            line: 107,
            constructor: "JSONEncoder"
        ),
        // Drop completion handler for the inbox payload. One per drop event.
        KnownSite(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/TaskBoard/TaskBoardLaneViews.swift",
            line: 136,
            constructor: "JSONDecoder"
        ),
        // Default-parameter sentinel on
        // `DecisionAuditTrailPayloadPresentation.init`. Callers on the per-row
        // path (`SessionDecisionRuntime`) already inject a shared decoder so
        // the default fires only from non-hot paths and tests.
        KnownSite(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/Decisions/DecisionAuditTrailTab.swift",
            line: 179,
            constructor: "JSONDecoder"
        ),
        // Same shape for `SessionTimelineDecisionSnapshot.init`. The timeline
        // index in `SessionTimelineNodeBuilder` injects a shared decoder for
        // the per-row construction path.
        KnownSite(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/Timeline/SessionTimelineDecisionSnapshot.swift",
            line: 160,
            constructor: "JSONDecoder"
        ),
        // Same default-parameter sentinel on the plain-input initializer.
        // Production timeline presentation uses `SessionTimelineNodeBuilder`,
        // which injects one decoder per worker compute; this default is for
        // direct tests and non-hot helper construction.
        KnownSite(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/Timeline/SessionTimelineDecisionSnapshot.swift",
            line: 164,
            constructor: "JSONDecoder"
        ),
        // Local decoder threaded into N snapshot inits during a one-shot data
        // refresh (`auditEvents(forSessionID:decisions:)`). Allocated once
        // per refresh, not per render.
        KnownSite(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/Sessions/SessionDecisionRuntime.swift",
            line: 149,
            constructor: "JSONDecoder"
        ),
        // SceneStorage codec helper. `decodePipelineStateMap` runs when the
        // scene state restores, not on view body re-evaluation.
        KnownSite(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/PolicyCanvas/PolicyCanvasView+SceneStorage.swift",
            line: 134,
            constructor: "JSONDecoder"
        ),
        // Same SceneStorage codec, encode side. Fires on scene-state writes,
        // not per frame.
        KnownSite(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/PolicyCanvas/PolicyCanvasView+SceneStorage.swift",
            line: 147,
            constructor: "JSONEncoder"
        ),
        // Date formatting cache for timeline row materialisation. This struct
        // is created inside the presentation worker compute, not from SwiftUI
        // `body`, and each formatter is then reused across all rows in that
        // worker pass.
        KnownSite(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/Timeline/SessionTimelineDayDivider.swift",
            line: 140,
            constructor: "DateFormatter"
        ),
        // Local decoder threaded into N snapshot inits inside the timeline
        // index build. Allocated once per index construction, then shared
        // across all snapshots in that build.
        KnownSite(
            relativePath:
                "Sources/HarnessMonitorUIPreviewable/Views/Timeline/SessionTimelineNodeBuilder.swift",
            line: 259,
            constructor: "JSONDecoder"
        ),
    ]

    func testBannedConstructorsDoNotAllocateInBodyPaths() throws {
        let sites = try collectConstructorSites()
        XCTAssertFalse(
            sites.isEmpty,
            "Scanner found zero constructor sites; regex or walker is broken."
        )

        let scannedConstructors = Set(sites.map(\.constructor))
        XCTAssertGreaterThanOrEqual(
            scannedConstructors.count,
            1,
            "Scanner must observe at least one banned constructor under Views/."
        )

        var violations: [ConstructorSite] = []
        var matchedKnown: Set<KnownSite> = []

        for site in sites where !site.hasStaticCacheDeclaration {
            let candidate = KnownSite(
                relativePath: site.relativePath,
                line: site.line,
                constructor: site.constructor
            )
            if Self.knownAcceptedSites.contains(candidate) {
                matchedKnown.insert(candidate)
            } else {
                violations.append(site)
            }
        }

        let staleAllowlist = Self.knownAcceptedSites.filter { entry in
            !matchedKnown.contains(entry)
        }

        if !violations.isEmpty {
            let detail =
                violations
                .map { site in
                    "  \(site.relativePath):\(site.line) -> \(site.constructor)()"
                }
                .joined(separator: "\n")
            XCTFail(
                """
                Found \(violations.count) inline allocation site(s) of a banned \
                Foundation formatter/encoder under Views/. Move each to a \
                module-scope or type-scope cache (see \
                Sources/HarnessMonitorUIPreviewable/Theme/HarnessMonitorFormatters.swift).

                Sites:
                \(detail)
                """
            )
        }

        if !staleAllowlist.isEmpty {
            let detail =
                staleAllowlist
                .map { entry in
                    "  \(entry.relativePath):\(entry.line) -> \(entry.constructor)()"
                }
                .joined(separator: "\n")
            XCTFail(
                """
                `knownAcceptedSites` contains \(staleAllowlist.count) entr(y/ies) \
                that no longer match a real site. Remove or update them — the \
                allowlist is not allowed to drift.

                Stale entries:
                \(detail)
                """
            )
        }
    }

    // MARK: - Scanner

    private struct ConstructorSite {
        let relativePath: String
        let line: Int
        let constructor: String
        let hasStaticCacheDeclaration: Bool
    }

    private struct KnownSite: Hashable {
        let relativePath: String
        let line: Int
        let constructor: String
    }

    private func collectConstructorSites() throws -> [ConstructorSite] {
        let viewsRoot = appRootURL.appendingPathComponent(
            "Sources/HarnessMonitorUIPreviewable/Views"
        )
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: viewsRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            XCTFail("Failed to enumerate \(viewsRoot.path)")
            return []
        }

        let pattern = constructorPattern()
        let regex = try NSRegularExpression(pattern: pattern)

        var sites: [ConstructorSite] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let relativePath = relativePath(for: fileURL)
            sites.append(
                contentsOf: scanSource(
                    source,
                    relativePath: relativePath,
                    regex: regex
                )
            )
        }
        sites.sort { lhs, rhs in
            if lhs.relativePath != rhs.relativePath {
                return lhs.relativePath < rhs.relativePath
            }
            return lhs.line < rhs.line
        }
        return sites
    }

    /// Builds a single regex covering every banned constructor as a separate
    /// capture group. The group index decides which type matched, which we
    /// turn back into the type's name for the diagnostic.
    private func constructorPattern() -> String {
        let alternation = Self.bannedTypes.joined(separator: "|")
        return "(\(alternation))\\(\\)"
    }

    private func scanSource(
        _ source: String,
        relativePath: String,
        regex: NSRegularExpression
    ) -> [ConstructorSite] {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
            .map(String.init)
        var sites: [ConstructorSite] = []
        for (index, line) in lines.enumerated() {
            if isCommentLine(line) { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for match in regex.matches(in: line, range: range) {
                guard
                    match.numberOfRanges >= 2,
                    let typeRange = Range(match.range(at: 1), in: line)
                else { continue }
                let constructor = String(line[typeRange])
                let hasDeclaration = lineOrPrecedingHasAcceptedDeclaration(
                    lines: lines,
                    lineIndex: index
                )
                sites.append(
                    ConstructorSite(
                        relativePath: relativePath,
                        line: index + 1,
                        constructor: constructor,
                        hasStaticCacheDeclaration: hasDeclaration
                    )
                )
            }
        }
        return sites
    }

    /// Skip `//` and `///` comment lines so doc-comment mentions of a banned
    /// type (e.g. "see `JSONDecoder()`") don't trip the scanner. Block
    /// comments are rare in the codebase and are not handled.
    private func isCommentLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("//")
    }

    /// Walks the match line and three preceding lines looking for any of the
    /// documented static/instance cache declaration tokens. This covers
    /// IIFE-style caches (`@MainActor private let foo: T = { let bar = T() ... }()`)
    /// where the constructor lands on a subsequent line.
    private func lineOrPrecedingHasAcceptedDeclaration(
        lines: [String],
        lineIndex: Int
    ) -> Bool {
        let lowerBound = max(0, lineIndex - 3)
        for cursor in lowerBound...lineIndex {
            let candidate = lines[cursor]
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            for prefix in Self.acceptedDeclarationPrefixes
            where trimmed.hasPrefix(prefix) {
                return true
            }
        }
        return false
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
