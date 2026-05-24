import Foundation
import XCTest

/// Contract test that protects the startup focus / search / inspector gate.
///
/// First-frame churn of the SwiftUI focused-value tree is the highest-value
/// regression zone for `FocusedValue update tried to update multiple times
/// per frame` warnings and CPU spikes. The Session window stages this with a
/// single `isStartupSearchParticipationEnabled` boolean (declared on
/// `SessionWindowView`), which:
///
///   1. publishes `nil` for `\.sessionNavigation`, `\.sessionAttention`,
///      `\.sessionInspector` until the snapshot has loaded
///   2. flips to `true` exactly once at the tail of `performInitialLoad()`
///      via `enableStartupSearchParticipation()`
///   3. gates whether the search host receives `isEnabled: true`
///
/// These three rules pin that contract by scanning the Swift sources under
/// `apps/harness-monitor/Sources/`. The contract is structural — if any
/// of the participating files lose their reference to the gate, or a new
/// publisher of one of the session FocusedValue keys is added without
/// guarding on the gate, this test fails with file:line context.
final class StartupFocusGateContractTests: XCTestCase {
    /// Symbol name of the startup gate property on `SessionWindowView`. Every
    /// rule below pivots on this exact identifier; if the underlying storage
    /// is renamed update the constant here as well as the property itself.
    private static let gateSymbol = "isStartupSearchParticipationEnabled"

    /// Relative path (from the macOS app root) of the only file allowed to
    /// flip the gate to `true`. Reset-to-`false` is permitted elsewhere as
    /// long as the choke-point for enabling stays here.
    private static let presentationFileRelativePath =
        "Sources/HarnessMonitorUIPreviewable/Views/Sessions/SessionWindowView+Presentation.swift"

    /// Relative path of the file that mounts the search host. This file must
    /// read the gate; the search infrastructure is the consumer that turns
    /// the gate into observable behaviour.
    private static let searchHostFileRelativePath =
        "Sources/HarnessMonitorUIPreviewable/Views/Sessions/SessionWindowView+SearchHost.swift"

    /// Regex matching any FocusedValue publishing call (the bare SwiftUI
    /// `focusedSceneValue` modifier or the in-app `harnessFocusedSceneValue`
    /// deferred wrapper) for a session-prefixed key. The key family covers
    /// the three published values today (`sessionNavigation`,
    /// `sessionAttention`, `sessionInspector`) plus future additions that
    /// follow the `session<Word>(Focus|Inspector|Attention|Navigation)`
    /// naming convention. `\.sessionFocus` is included explicitly so a
    /// hypothetical future literal also lands inside the gate.
    private static let sessionFocusPublishPattern =
        #"[fF]ocusedSceneValue\([^,]*\\\.session(Focus|Navigation|Attention|Inspector|[A-Z][a-zA-Z]*(Focus|Inspector|Attention|Navigation))\b"#

    /// Regex for assignments that flip the gate to `true`. Both the helper
    /// `enableStartupSearchParticipation()` call and a direct
    /// `isStartupSearchParticipationEnabled = true` literal count; the helper
    /// is the recommended path, but a future inline assignment would still
    /// violate the choke-point rule.
    private static let gateFlipTruePattern =
        #"enableStartupSearchParticipation\s*\(|isStartupSearchParticipationEnabled\s*=\s*true\b"#

    // MARK: - 1. Publishers guard on the startup gate

    func testSessionFocusedValuePublishersGuardOnStartupGate() throws {
        let sources = try collectSwiftSources()
        let publishRegex = try NSRegularExpression(
            pattern: Self.sessionFocusPublishPattern
        )

        var violations: [String] = []
        var publisherCount = 0

        for file in sources {
            let strippedSource = stripComments(from: file.source)
            let lines = matchLineNumbers(in: strippedSource, regex: publishRegex)
            guard !lines.isEmpty else { continue }
            publisherCount += lines.count
            if !file.source.contains(Self.gateSymbol) {
                let detail = lines.map { "\(file.relativePath):\($0)" }
                violations.append(contentsOf: detail)
            }
        }

        XCTAssertGreaterThan(
            publisherCount,
            0,
            """
            Scanner found no session-FocusedValue publishers under Sources/. \
            Pattern is likely broken; today's known sites are in \
            Sources/HarnessMonitorUIPreviewable/Views/Sessions/\
            SessionWindowView+FocusedValues.swift.
            """
        )

        if !violations.isEmpty {
            XCTFail(
                """
                Found \(violations.count) session FocusedValue publisher \
                site(s) in files that do not reference `\(Self.gateSymbol)`.
                Every publisher of \\.sessionNavigation / \\.sessionAttention \
                / \\.sessionInspector (or any \\.session*Focus*/Inspector/\
                Attention/Navigation key) must guard on the startup gate, \
                so the first frame does not publish multiple focused values \
                simultaneously. Add the gate reference (read or guard) to \
                each offending file, or route the publish through \
                SessionWindowView+FocusedValues.swift.

                Sites:
                \(violations.joined(separator: "\n"))
                """
            )
        }
    }

    // MARK: - 2. Flag only flips in Presentation

    func testStartupSearchParticipationFlagOnlyFlipsInPresentation() throws {
        let sources = try collectSwiftSources()
        let flipRegex = try NSRegularExpression(pattern: Self.gateFlipTruePattern)
        let presentationPath = Self.presentationFileRelativePath

        var unexpectedFlipSites: [String] = []
        var presentationFlipLines: [Int] = []

        for file in sources {
            let strippedSource = stripComments(from: file.source)
            let lines = matchLineNumbers(in: strippedSource, regex: flipRegex)
            guard !lines.isEmpty else { continue }
            if file.relativePath == presentationPath {
                presentationFlipLines = lines
            } else if file.relativePath.hasSuffix(
                "Views/Sessions/SessionWindowView.swift"
            ) {
                // SessionWindowView.swift owns the storage. It defines
                // `enableStartupSearchParticipation()` and the
                // `isStartupSearchParticipationEnabled = true` assignment
                // inside that helper. The helper itself is the choke-point
                // implementation; the *caller* is what this rule pins.
                continue
            } else {
                let detail = lines.map { "\(file.relativePath):\($0)" }
                unexpectedFlipSites.append(contentsOf: detail)
            }
        }

        XCTAssertFalse(
            presentationFlipLines.isEmpty,
            """
            Expected `\(presentationPath)` to flip the startup gate to \
            true (via `enableStartupSearchParticipation()` or a direct \
            assignment). Found no such site; performInitialLoad() may have \
            stopped enabling participation.
            """
        )

        if !unexpectedFlipSites.isEmpty {
            XCTFail(
                """
                Found \(unexpectedFlipSites.count) site(s) flipping \
                `\(Self.gateSymbol)` to true outside the allowed \
                choke-point `\(presentationPath)`. The gate must be enabled \
                at one place (the tail of performInitialLoad) so the first \
                frame stays calm. Move the flip there, or route through \
                `enableStartupSearchParticipation()` called from \
                performInitialLoad.

                Sites:
                \(unexpectedFlipSites.joined(separator: "\n"))
                """
            )
        }
    }

    // MARK: - 3. Search host reads the gate

    func testSearchHostMountReadsTheGate() throws {
        let path = appRootURL.appendingPathComponent(
            Self.searchHostFileRelativePath
        )
        let source = try String(contentsOf: path, encoding: .utf8)
        let strippedSource = stripComments(from: source)

        XCTAssertTrue(
            strippedSource.contains(Self.gateSymbol),
            """
            `\(Self.searchHostFileRelativePath)` must read \
            `\(Self.gateSymbol)` when mounting the AppSearchHost. The \
            gate decides whether the search infrastructure participates \
            on the first frame; if the search host stops reading it, the \
            startup-search storm regression returns. Restore the \
            `isEnabled:` argument (or equivalent gate-aware mount).
            """
        )
    }

    // MARK: - Scanner support

    private struct SwiftSource {
        let relativePath: String
        let source: String
    }

    private func collectSwiftSources() throws -> [SwiftSource] {
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

        var collected: [SwiftSource] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            collected.append(
                SwiftSource(
                    relativePath: relativePath(for: fileURL),
                    source: text
                )
            )
        }
        collected.sort { $0.relativePath < $1.relativePath }
        return collected
    }

    private func matchLineNumbers(
        in source: String,
        regex: NSRegularExpression
    ) -> [Int] {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, range: range)
        guard !matches.isEmpty else { return [] }
        return matches.compactMap { match in
            guard let matchRange = Range(match.range, in: source) else {
                return nil
            }
            let prefix = source[source.startIndex..<matchRange.lowerBound]
            return prefix.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
        }
    }

    /// Replaces `//`-style line comments and `/* ... */` block comments with
    /// space-padded equivalents that preserve newline count and total length,
    /// so line numbers from `matchLineNumbers` still point at the original
    /// source. Strings are left intact; the regex does not match string
    /// literal contents because string-form FocusedValue keys do not exist
    /// in this codebase.
    private func stripComments(from source: String) -> String {
        var output: [Character] = []
        output.reserveCapacity(source.count)
        let scalars = Array(source)
        var index = 0
        while index < scalars.count {
            let character = scalars[index]
            if character == "/" && index + 1 < scalars.count {
                let next = scalars[index + 1]
                if next == "/" {
                    while index < scalars.count, scalars[index] != "\n" {
                        output.append(" ")
                        index += 1
                    }
                    continue
                }
                if next == "*" {
                    output.append(" ")
                    output.append(" ")
                    index += 2
                    while index < scalars.count {
                        if
                            scalars[index] == "*",
                            index + 1 < scalars.count,
                            scalars[index + 1] == "/"
                        {
                            output.append(" ")
                            output.append(" ")
                            index += 2
                            break
                        }
                        output.append(scalars[index] == "\n" ? "\n" : " ")
                        index += 1
                    }
                    continue
                }
            }
            output.append(character)
            index += 1
        }
        return String(output)
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
