import Foundation
import XCTest
@testable import HarnessMonitorPerfCore

/// Contract test that pins the SwiftUI style discipline rule:
///
/// `.buttonStyle(.plain)` and the `harnessPlainButtonStyle()` helper must remain
/// limited to reviewed call sites whose labels draw their complete interactive
/// chrome. PolicyCanvas owns many such controls, so that surface is reviewed as
/// a unit; every use elsewhere is pinned by a unique local marker and file.
final class PlainButtonStyleContractTests: XCTestCase {
    private struct ReviewedSite {
        let path: String
        let fingerprint: String
    }

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
    private static let reviewMarkerPrefix = "// monitor-perf: plain-button "

    private static let reviewedProductChromeSites = [
        // The palette draws selection, hover, section, and search-field chrome.
        "open-anything-row": ReviewedSite(
            path: "App/OpenAnythingPaletteRow.swift", fingerprint: "950f6a56edaf5674"),
        "open-anything-section-collapse": ReviewedSite(
            path: "App/OpenAnythingPaletteSectionHeader.swift", fingerprint: "4e6f1873dd88383b"),
        "open-anything-section-expand": ReviewedSite(
            path: "App/OpenAnythingPaletteSectionHeader.swift", fingerprint: "d12b4ddc4f82c1f8"),
        "open-anything-query-clear": ReviewedSite(
            path: "App/OpenAnythingPaletteView.swift", fingerprint: "5c1d3c66cfeb4152"),
        // These dashboard controls are complete rows, pills, thumbnails, text
        // links, or icon targets with their own hit regions and visual states.
        "audit-timeline-load-more": ReviewedSite(
            path: "Dashboard/DashboardAuditRouteView+Timeline.swift",
            fingerprint: "1095c6acf9f8945d"),
        "audit-timeline-row": ReviewedSite(
            path: "Dashboard/DashboardAuditRouteView+Timeline.swift",
            fingerprint: "fc8da4bc1daa1cab"),
        "ocr-result-preview": ReviewedSite(
            path: "Dashboard/DashboardDebuggingOCRResultCard.swift",
            fingerprint: "6ea3d95608a280d1"),
        "review-backport-pill": ReviewedSite(
            path: "Dashboard/DashboardReviewBackportMetadataPill.swift",
            fingerprint: "227edb40081a1d8a"),
        "review-check-row-link": ReviewedSite(
            path: "Dashboard/DashboardReviewCheckRow.swift", fingerprint: "240587fc6f918f80"),
        "review-check-rerun": ReviewedSite(
            path: "Dashboard/DashboardReviewCheckRow.swift", fingerprint: "6726f073c1aabaa9"),
        "review-check-copy-url": ReviewedSite(
            path: "Dashboard/DashboardReviewCheckRow.swift", fingerprint: "07cd82e64a5b4e68"),
        "review-comment-error-dismiss": ReviewedSite(
            path: "Dashboard/DashboardReviewCommentRetryStrip.swift",
            fingerprint: "6bdc05eefcceec9b"),
        "review-detail-title-link": ReviewedSite(
            path: "Dashboard/DashboardReviewDetailSupport.swift", fingerprint: "c0435cf7d0ff1e2d"),
        "review-files-tree-node": ReviewedSite(
            path: "Dashboard/DashboardReviewFilesTree.swift", fingerprint: "5c556aed8b098691"),
        "review-inline-thread-collapse": ReviewedSite(
            path: "Dashboard/DashboardReviewInlineThreadCard.swift",
            fingerprint: "ff97246ef437390a"),
        "review-search-suggestion": ReviewedSite(
            path: "Dashboard/DashboardReviewsRouteView+ToolbarSearch.swift",
            fingerprint: "5262e4d7afc7b9ae"),
        "review-refresh-timeout-dismiss": ReviewedSite(
            path: "Dashboard/DashboardReviewsRouteView+TransientBanners.swift",
            fingerprint: "d4ae2c580c3d6a93"),
        // The swatch is the button chrome and carries an explicit selected trait.
        "task-board-project-color-swatch": ReviewedSite(
            path: "Settings/SettingsTaskBoardProjectAppearanceSection.swift",
            fingerprint: "d29f4cdae6b87d25"),
        // Lane headers, collapsed lanes, and quick-add rows draw card chrome and
        // pointer feedback across their full custom hit regions.
        "task-board-collapsed-lane": ReviewedSite(
            path: "TaskBoard/TaskBoardCollapsedLane.swift", fingerprint: "598c923bfc9182d9"),
        "task-board-lane-header": ReviewedSite(
            path: "TaskBoard/TaskBoardLaneChrome.swift", fingerprint: "f5a283b97c6718af"),
        "task-board-lane-quick-add": ReviewedSite(
            path: "TaskBoard/TaskBoardLaneQuickAddRow.swift", fingerprint: "01d355f38865875f"),
        "task-board-lane-quick-add-dismiss": ReviewedSite(
            path: "TaskBoard/TaskBoardLaneQuickAddRow.swift", fingerprint: "acd11e54bb0da345"),
    ]

    func testPlainButtonStyleOnlyAppearsInReviewedSites() throws {
        let viewsRoot = appRootURL.appendingPathComponent(Self.previewableViewsRelativePath)
        let regex = try NSRegularExpression(pattern: Self.plainButtonPattern)
        let definitionFileURL = appRootURL
            .appendingPathComponent(Self.definitionFileRelativePath)
            .standardizedFileURL

        var actualSites: [String: [(path: String, line: Int, fingerprint: String)]] = [:]
        var unmarkedSites: [String] = []

        for swiftFileURL in try swiftFiles(under: viewsRoot) {
            if swiftFileURL.standardizedFileURL == definitionFileURL {
                continue
            }
            let path = swiftFileURL.path
            if path.contains(Self.allowedSubpathFragment) {
                continue
            }
            let source = try String(contentsOf: swiftFileURL, encoding: .utf8)
            let relativePath = String(path.dropFirst(viewsRoot.path.count + 1))
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            for lineNumber in matchLineNumbers(in: source, regex: regex) {
                let line = String(lines[lineNumber - 1])
                guard let marker = reviewMarker(in: line) else {
                    unmarkedSites.append("\(relativePath):\(lineNumber)")
                    continue
                }
                let fingerprint = callSiteFingerprint(lines: lines, lineNumber: lineNumber)
                actualSites[marker, default: []].append((relativePath, lineNumber, fingerprint))
            }
        }

        let reviewedMarkers = Set(Self.reviewedProductChromeSites.keys)
            .union(actualSites.keys)
            .sorted()
        var mismatches = unmarkedSites.map { "unmarked call at \($0)" }
        for marker in reviewedMarkers {
            guard let expectedSite = Self.reviewedProductChromeSites[marker] else {
                let locations = actualSites[marker, default: []]
                    .map { "\($0.path):\($0.line)" }
                    .joined(separator: ", ")
                mismatches.append("unexpected marker \(marker) at \(locations)")
                continue
            }
            let locations = actualSites[marker, default: []]
            guard locations.count == 1, let location = locations.first else {
                mismatches.append("marker \(marker) expected once, found \(locations.count)")
                continue
            }
            if location.path != expectedSite.path {
                mismatches.append(
                    "marker \(marker) expected in \(expectedSite.path), found \(location.path):\(location.line)"
                )
            } else if location.fingerprint != expectedSite.fingerprint {
                mismatches.append(
                    "marker \(marker) call-site context changed at \(location.path):\(location.line); "
                        + "expected \(expectedSite.fingerprint), found \(location.fingerprint)"
                )
            }
        }

        XCTAssertTrue(
            mismatches.isEmpty,
            """
            `.buttonStyle(.plain)` / `.harnessPlainButtonStyle()` changed outside the \
            PolicyCanvas surface. Review the complete button chrome, then add or move a unique \
            local marker only when the exact call site is intentional:
            \(mismatches.joined(separator: "\n"))
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

    private func reviewMarker(in line: String) -> String? {
        guard let markerRange = line.range(of: Self.reviewMarkerPrefix) else { return nil }
        let marker = line[markerRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return marker.isEmpty ? nil : marker
    }

    private func callSiteFingerprint(lines: [Substring], lineNumber: Int) -> String {
        let lineIndex = lineNumber - 1
        let firstIndex = max(0, lineIndex - 10)
        let lastIndex = min(lines.count - 1, lineIndex + 4)
        let context = lines[firstIndex...lastIndex].joined(separator: "\n")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in context.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
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
