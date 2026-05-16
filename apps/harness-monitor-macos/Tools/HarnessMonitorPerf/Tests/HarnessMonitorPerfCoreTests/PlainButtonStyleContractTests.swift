import Foundation
import XCTest
@testable import HarnessMonitorPerfCore

/// Contract test that pins the SwiftUI style discipline rule:
///
/// `.buttonStyle(.plain)` and the `harnessPlainButtonStyle()` helper must not
/// appear in product chrome (sidebars, toolbars, inspectors, list rows,
/// settings forms). They are permitted inside the PolicyCanvas graph-drawing
/// surface, where opting out of native button chrome is a deliberate visual
/// choice.
final class PlainButtonStyleContractTests: XCTestCase {
    private static let plainButtonPattern = #"\.buttonStyle\(\.plain\)|\.harnessPlainButtonStyle\(\)"#
    private static let harnessPlainButtonDefinitionPattern = #"func\s+harnessPlainButtonStyle"#

    /// The wrapper itself is defined inside `HarnessMonitorControls.swift`, so
    /// its `buttonStyle(.plain)` body legitimately matches the caller pattern.
    /// Skip the definition file entirely; the second test (below) pins the
    /// helper's definition site separately so accidental reintroduction in
    /// another file still fails.
    private static let definitionFileRelativePath =
        "Sources/HarnessMonitorUIPreviewable/Views/Shared/HarnessMonitorControls.swift"

    private static let previewableViewsRelativePath =
        "Sources/HarnessMonitorUIPreviewable/Views"

    private static let allowedSubpathFragment = "/PolicyCanvas/"

    func testPlainButtonStyleOnlyAppearsInPolicyCanvas() throws {
        let viewsRoot = appRootURL.appendingPathComponent(Self.previewableViewsRelativePath)
        let regex = try NSRegularExpression(pattern: Self.plainButtonPattern)
        let definitionFileURL = appRootURL
            .appendingPathComponent(Self.definitionFileRelativePath)
            .standardizedFileURL

        var violations: [String] = []

        for swiftFileURL in try swiftFiles(under: viewsRoot) {
            if swiftFileURL.standardizedFileURL == definitionFileURL {
                continue
            }
            let path = swiftFileURL.path
            if path.contains(Self.allowedSubpathFragment) {
                continue
            }
            let source = try String(contentsOf: swiftFileURL, encoding: .utf8)
            let lineNumbers = matchLineNumbers(in: source, regex: regex)
            for lineNumber in lineNumbers {
                violations.append("\(path):\(lineNumber)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            `.buttonStyle(.plain)` / `.harnessPlainButtonStyle()` is only allowed inside the \
            PolicyCanvas surface. Offending callers:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    func testHarnessPlainButtonStyleDefinitionLives_inExpectedPlace() throws {
        let viewsRoot = appRootURL.appendingPathComponent(Self.previewableViewsRelativePath)
        let regex = try NSRegularExpression(pattern: Self.harnessPlainButtonDefinitionPattern)
        let allowedDefinitionURL = appRootURL
            .appendingPathComponent(Self.definitionFileRelativePath)
            .standardizedFileURL

        var definitionSites: [String] = []

        for swiftFileURL in try swiftFiles(under: viewsRoot) {
            let source = try String(contentsOf: swiftFileURL, encoding: .utf8)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            if regex.firstMatch(in: source, range: range) != nil {
                definitionSites.append(swiftFileURL.standardizedFileURL.path)
            }
        }

        XCTAssertEqual(
            definitionSites,
            [allowedDefinitionURL.path],
            """
            `harnessPlainButtonStyle()` must only be defined in \
            \(allowedDefinitionURL.path). Found definitions in:
            \(definitionSites.joined(separator: "\n"))
            """
        )
    }

    private func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            XCTFail("Unable to enumerate \(directory.path)")
            return []
        }
        var files: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            files.append(fileURL)
        }
        return files.sorted { $0.path < $1.path }
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

    private var appRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
