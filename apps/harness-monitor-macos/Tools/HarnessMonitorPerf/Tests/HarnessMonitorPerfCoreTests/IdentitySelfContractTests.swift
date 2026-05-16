import Foundation
import XCTest

/// Enforces a SwiftUI identity rule: `id: \.self` is acceptable on `.allCases`
/// or pre-sorted/filtered enum collections, but must NOT appear on model
/// collections (decisions, sessions, agents, timeline nodes, anything with
/// potentially-duplicating data). Bad identifiers there cause performance and
/// state-loss bugs.
///
/// This test scans every Swift file under `apps/harness-monitor-macos/Sources/`,
/// finds each `id: \.self` site, captures the collection expression it is
/// attached to, and requires that expression to match a documented allowlist.
final class IdentitySelfContractTests: XCTestCase {
    /// Substrings that mark a collection as safe to identify by `\.self`.
    /// A match is allowed if the captured collection expression contains any
    /// of these tokens. Update the comments whenever a new entry is added so
    /// the rationale stays visible at the call site.
    private static let allowlistedCollectionTokens: [String] = [
        // Enum case iteration (always unique).
        ".allCases",
        // Pre-sorted enum array on DecisionSeverity.sidebarOrdering.
        ".sidebarOrdering",
        // Filtered enum subset on TaskBoardExternalRefProvider.taskBoardCases.
        ".taskBoardCases",
        // Filtered enum subset on TaskStatus.genericStatusChoices.
        ".genericStatusChoices",
        // Labeled enum subset on SendUpdateAction.allLabeledCases.
        ".allLabeledCases",
        // Static enum-string array on PolicyCanvasInspectorViews.
        "policyKindOptions",
        // Small fixed string array of Codex effort levels.
        "effortValues",
        // Same source as effortValues; threaded through SessionWindowCreateForm
        // bindings. Listed explicitly because the camelCase boundary breaks the
        // substring match against `effortValues`.
        "codexEffortValues",
        // [SessionRole] enum array passed into AgentDetailActionSections.
        "rolePickerValues",
        // Returns [String] node ids derived from canvas-scoped counters that
        // are guaranteed unique within the view model's node set.
        "accessibilityNodeFocusOrder()",
        // Fixed [SessionCreateKind] literal [.agent, .task, .decision].
        "orderedKinds",
        // Sorted unique [String] from Foundation's
        // TimeZone.knownTimeZoneIdentifiers; uniqueness is system-guaranteed.
        "knownTimeZoneIdentifiers",
    ]

    func testEveryIdSelfSiteUsesAnAllowlistedCollection() throws {
        let sites = try collectIdSelfSites()
        XCTAssertFalse(
            sites.isEmpty,
            "Walker found no `id: \\.self` sites; scanner is likely broken."
        )

        let violations = sites.filter { site in
            !Self.allowlistedCollectionTokens.contains { token in
                site.collectionExpression.contains(token)
            }
        }

        if !violations.isEmpty {
            let detail = violations
                .map { site in
                    "  \(site.relativePath):\(site.line) -> \(site.collectionExpression)"
                }
                .joined(separator: "\n")
            XCTFail(
                """
                Found \(violations.count) `id: \\.self` site(s) outside the allowlist.
                Either update the underlying view to use a stable identifier
                (`id: \\.id` on a `Identifiable` model) or, if the collection
                is provably duplicate-safe, add a token to
                `IdentitySelfContractTests.allowlistedCollectionTokens`
                with a comment explaining why.

                Sites:
                \(detail)
                """
            )
        }
    }

    func testKnownGoodSitesArePresent() throws {
        let sites = try collectIdSelfSites()
        XCTAssertGreaterThanOrEqual(
            sites.count,
            5,
            "Expected at least 5 `id: \\.self` sites under Sources/, found \(sites.count)."
        )
    }

    // MARK: - Scanner

    private struct IdSelfSite {
        let relativePath: String
        let line: Int
        let collectionExpression: String
    }

    private func collectIdSelfSites() throws -> [IdSelfSite] {
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

        var sites: [IdSelfSite] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let relativePath = relativePath(for: fileURL)
            sites.append(contentsOf: scanSource(source, relativePath: relativePath))
        }
        sites.sort { lhs, rhs in
            if lhs.relativePath != rhs.relativePath {
                return lhs.relativePath < rhs.relativePath
            }
            return lhs.line < rhs.line
        }
        return sites
    }

    private func scanSource(_ source: String, relativePath: String) -> [IdSelfSite] {
        let pattern = #"id:\s*\\\.self"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var sites: [IdSelfSite] = []
        for match in regex.matches(in: source, range: range) {
            guard let matchRange = Range(match.range, in: source) else { continue }
            let collectionExpression = extractCollectionExpression(
                in: source,
                upTo: matchRange.lowerBound
            )
            let line = lineNumber(of: matchRange.lowerBound, in: source)
            sites.append(
                IdSelfSite(
                    relativePath: relativePath,
                    line: line,
                    collectionExpression: collectionExpression
                )
            )
        }
        return sites
    }

    /// Walks backwards from `cursor` and returns the trimmed text between the
    /// nearest unmatched `(` and the comma that precedes `id: \.self`. This
    /// is intentionally lightweight: it tracks nesting depth so calls like
    /// `viewModel.accessibilityNodeFocusOrder()` are kept intact, and stops at
    /// the outer call's open-paren.
    private func extractCollectionExpression(
        in source: String,
        upTo cursor: String.Index
    ) -> String {
        // Find the comma immediately before `id:` by scanning back over
        // whitespace and locating the first `,`.
        var index = cursor
        while index > source.startIndex {
            index = source.index(before: index)
            let character = source[index]
            if character == "," {
                break
            }
            if !character.isWhitespace {
                // Some sites (none today) might use a parenthesized form like
                // `(collection, id: \.self)` on a single line without a comma
                // immediately before. If we hit a non-comma non-whitespace,
                // fall through and let the back-walker capture whatever it
                // can; the allowlist match still has the final say.
                break
            }
        }
        let commaIndex = index

        // Walk back from the comma to the matching open-paren, tracking
        // nested parens/brackets so we don't bail early on inner calls or
        // collection literals.
        var depth = 0
        var startIndex = commaIndex
        var walker = commaIndex
        while walker > source.startIndex {
            walker = source.index(before: walker)
            let character = source[walker]
            if character == ")" || character == "]" || character == "}" {
                depth += 1
            } else if character == "(" || character == "[" || character == "{" {
                if depth == 0 {
                    startIndex = source.index(after: walker)
                    break
                }
                depth -= 1
            }
        }

        let slice = source[startIndex..<commaIndex]
        return slice
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
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
