import Foundation
import XCTest

/// Contract test that pins where `.backgroundExtensionEffect()` may be
/// applied. The modifier extends the window's chrome glass into the content
/// area, so nesting it under another glass host or applying it inside content
/// rows produces "glass on glass" stacking that washes out the underlying
/// material and adds redundant blur passes.
///
/// Direct `.backgroundExtensionEffect(` callers must live in the documented
/// helper file. Every other surface routes through the
/// `sessionWindowBackgroundExtensionEffect()` /
/// `harnessMonitorToolbarBackgroundExtensionEffect()` /
/// `harnessMonitorBackgroundExtensionEffect()` wrappers so the test-environment
/// opt-out and `accessibilityReduceTransparency` handling stay centralised.
/// General backdrop surfaces also keep the user backdrop-mode gate there.
final class GlassHostContractTests: XCTestCase {
    /// Files allowed to invoke `.backgroundExtensionEffect(` directly.
    /// Add a comment for each entry explaining why the raw call site is
    /// legitimate; every other site should route through one of the
    /// `*BackgroundExtensionEffect()` wrappers defined in the helper.
    private static let allowlistedRelativePaths: [String] = [
        // The wrapper implementation itself; its `content.backgroundExtensionEffect()`
        // body is the single canonical glass-host entry point. Every other
        // surface should call `sessionWindowBackgroundExtensionEffect()`,
        // `harnessMonitorToolbarBackgroundExtensionEffect()`, or
        // `harnessMonitorBackgroundExtensionEffect()` instead so the
        // accessibility and test-environment gating stay centralised.
        "Sources/HarnessMonitorUIPreviewable/Views/Sessions/SessionWindowBackgroundExtensionEffect.swift",
    ]

    private static let backgroundExtensionEffectPattern = #"\.backgroundExtensionEffect\("#

    func testEveryBackgroundExtensionEffectCallerIsAllowlisted() throws {
        let sites = try collectBackgroundExtensionEffectSites()
        XCTAssertFalse(
            sites.isEmpty,
            """
            Walker found no `.backgroundExtensionEffect(` sites under \
            Sources/. Either the helper has been deleted or the scanner is \
            broken; verify the wrapper file still applies the modifier.
            """
        )

        let allowlist = Set(Self.allowlistedRelativePaths)
        let violations = sites.filter { !allowlist.contains($0.relativePath) }

        if !violations.isEmpty {
            let detail = violations
                .map { "  \($0.relativePath):\($0.line)" }
                .joined(separator: "\n")
            XCTFail(
                """
                Found \(violations.count) raw `.backgroundExtensionEffect(` \
                site(s) outside the allowlist. Glass-host placement is \
                centralised; route the call through \
                `sessionWindowBackgroundExtensionEffect()`, \
                `harnessMonitorToolbarBackgroundExtensionEffect()`, or \
                `harnessMonitorBackgroundExtensionEffect()` so the \
                accessibility and test-environment gating in \
                `SessionWindowBackgroundExtensionEffect.swift` stays \
                authoritative. If a brand-new direct caller is genuinely \
                required, add its `Sources/...` relative path to \
                `GlassHostContractTests.allowlistedRelativePaths` with a \
                comment explaining why.

                Sites:
                \(detail)
                """
            )
        }
    }

    func testAllowlistedHostsAreActuallyPresent() throws {
        let sites = try collectBackgroundExtensionEffectSites()
        let foundPaths = Set(sites.map(\.relativePath))
        for expected in Self.allowlistedRelativePaths {
            XCTAssertTrue(
                foundPaths.contains(expected),
                """
                Expected allowlisted host \(expected) to contain at least \
                one `.backgroundExtensionEffect(` call site; none were \
                found. Either the helper moved (update the allowlist) or \
                the call site was deleted (remove the stale entry).
                """
            )
        }
    }

    // MARK: - Scanner

    private struct CallSite {
        let relativePath: String
        let line: Int
    }

    private func collectBackgroundExtensionEffectSites() throws -> [CallSite] {
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

        let regex = try NSRegularExpression(pattern: Self.backgroundExtensionEffectPattern)
        var sites: [CallSite] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let stripped = sourceWithCommentsStripped(source)
            let relativePath = relativePath(for: fileURL)
            for line in matchLineNumbers(in: stripped, regex: regex) {
                sites.append(CallSite(relativePath: relativePath, line: line))
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

    /// Replaces every character inside `//` line comments and `/* ... */`
    /// block comments with a space, except for newlines (which stay so line
    /// numbers report correctly). String literals are kept intact, so a
    /// `"// foo"` substring is not mistaken for a comment. Doc comments
    /// (`///`, `/** */`) collapse the same way as their non-doc equivalents.
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
                    output.append("  ") // two spaces for the original `//`
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

    private func matchLineNumbers(in source: String, regex: NSRegularExpression) -> [Int] {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, range: range)
        guard !matches.isEmpty else { return [] }
        return matches.compactMap { match in
            guard let matchRange = Range(match.range, in: source) else { return nil }
            let prefix = source[source.startIndex..<matchRange.lowerBound]
            return prefix.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
        }
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
