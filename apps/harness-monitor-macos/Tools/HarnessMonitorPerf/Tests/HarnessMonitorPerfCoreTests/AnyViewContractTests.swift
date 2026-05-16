import Foundation
import XCTest

/// Enforces a SwiftUI structural-identity rule: `AnyView(...)` must NOT appear
/// anywhere under `apps/harness-monitor-macos/Sources/`.
///
/// `AnyView` type-erases the wrapped view, which:
///   - destroys SwiftUI's structural identity inside `List` / `ForEach`
///     (every diff sees a fresh `AnyView`, so state is lost and rows churn),
///   - re-erases the modifier chain on every parent update, defeating the
///     comparison fast-path,
///   - hides the real view type from the runtime, making Instruments traces
///     hard to read.
///
/// Use `@ViewBuilder`, `Group`, `ViewModifier`, or `some View` instead. If a
/// legitimate type-erasure boundary is unavoidable (e.g. heterogeneous view
/// collections across module seams), allowlist the specific file with a
/// comment explaining why.
///
/// This test scans every `.swift` file under `apps/harness-monitor-macos/Sources/`
/// for `AnyView(` and reports `relativePath:line` for any non-allowlisted
/// occurrence.
final class AnyViewContractTests: XCTestCase {
    /// Relative paths (from the monitor app root) that are permitted to call
    /// `AnyView(...)`. Empty today: the product UI builds entirely on concrete
    /// `some View` returns. Adding an entry here is a code review event.
    private static let allowlistedRelativePaths: Set<String> = [
        // Intentionally empty. The product surface must not introduce
        // `AnyView` without first justifying the type-erasure boundary here.
    ]

    /// Substrings inside the captured line that mark the occurrence as
    /// non-source (doc comment, attribute, identifier reference). The regex
    /// already requires `AnyView(` with the open paren, so most prose
    /// references like "uses AnyView" are naturally excluded; this list is a
    /// belt-and-braces filter for borderline cases that may appear in future.
    private static let benignLinePrefixes: [String] = [
        // Triple-slash doc-comment lines never compile to a call.
        "///",
    ]

    func testNoAnyViewCallSitesUnderSources() throws {
        let sites = try collectAnyViewSites()

        let violations = sites.filter { site in
            !Self.allowlistedRelativePaths.contains(site.relativePath)
        }

        if !violations.isEmpty {
            let detail = violations
                .map { site in
                    "  \(site.relativePath):\(site.line) -> \(site.lineText)"
                }
                .joined(separator: "\n")
            XCTFail(
                """
                Found \(violations.count) `AnyView(` call site(s) under Sources/.
                `AnyView` type-erases the wrapped view, breaking SwiftUI's
                structural identity (state loss in List/ForEach), defeating
                the modifier-chain comparison fast-path, and hiding the real
                view type from Instruments.

                Use `@ViewBuilder`, `Group`, `ViewModifier`, or `some View`
                instead. If a genuine type-erasure boundary is unavoidable,
                add the file's relative path to
                `AnyViewContractTests.allowlistedRelativePaths` with a comment
                explaining the seam.

                Sites:
                \(detail)
                """
            )
        }
    }

    /// Sanity check: the scanner walks the same `Sources/` tree as the
    /// other contract tests. We don't assert a minimum number of `AnyView`
    /// sites (the project goal is zero) but we DO require that the walker
    /// found at least one Swift file — otherwise the scanner is broken and
    /// the contract would silently pass.
    func testScannerWalksSourcesTree() throws {
        let swiftFileCount = try countSwiftFiles()
        XCTAssertGreaterThan(
            swiftFileCount,
            0,
            "Walker found no Swift files under Sources/; scanner is broken."
        )
    }

    // MARK: - Scanner

    private struct AnyViewSite {
        let relativePath: String
        let line: Int
        let lineText: String
    }

    private func collectAnyViewSites() throws -> [AnyViewSite] {
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

        var sites: [AnyViewSite] = []
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

    private func scanSource(_ source: String, relativePath: String) -> [AnyViewSite] {
        // Matches `AnyView(` with optional whitespace before the paren and a
        // word-boundary prefix so identifiers like `SomeAnyView(` don't trip
        // the contract.
        let pattern = #"\bAnyView\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var sites: [AnyViewSite] = []
        for match in regex.matches(in: source, range: range) {
            guard let matchRange = Range(match.range, in: source) else { continue }
            let line = lineNumber(of: matchRange.lowerBound, in: source)
            let lineText = lineText(at: matchRange.lowerBound, in: source)
            if isBenign(lineText: lineText) {
                continue
            }
            sites.append(
                AnyViewSite(
                    relativePath: relativePath,
                    line: line,
                    lineText: lineText
                )
            )
        }
        return sites
    }

    private func isBenign(lineText: String) -> Bool {
        let trimmed = lineText.trimmingCharacters(in: .whitespaces)
        for prefix in Self.benignLinePrefixes where trimmed.hasPrefix(prefix) {
            return true
        }
        return false
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

    private func lineText(at index: String.Index, in source: String) -> String {
        var start = index
        while start > source.startIndex {
            let previous = source.index(before: start)
            if source[previous] == "\n" {
                break
            }
            start = previous
        }
        var end = index
        while end < source.endIndex, source[end] != "\n" {
            end = source.index(after: end)
        }
        return String(source[start..<end])
    }

    private func countSwiftFiles() throws -> Int {
        let sourcesRoot = appRootURL.appendingPathComponent("Sources")
        guard
            let enumerator = FileManager.default.enumerator(
                at: sourcesRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return 0
        }
        var count = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            count += 1
        }
        return count
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
