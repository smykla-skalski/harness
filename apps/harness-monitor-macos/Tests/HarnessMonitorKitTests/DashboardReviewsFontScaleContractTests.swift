import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews font-scale contracts")
struct DashboardReviewsFontScaleContractTests {
  @Test("Review diff typography follows the full app scale range")
  func reviewDiffTypographyFollowsFullAppScaleRange() {
    let minimumScale = HarnessMonitorTextSize.scale(at: 0)
    let maximumScale = HarnessMonitorTextSize.scale(at: HarnessMonitorTextSize.scales.count - 1)

    #expect(abs(DashboardReviewDiffTypography.pointSize(fontScale: 1.0) - 12) < 0.001)
    #expect(
      abs(
        DashboardReviewDiffTypography.pointSize(fontScale: minimumScale)
          - (DashboardReviewDiffTypography.basePointSize * minimumScale)
      ) < 0.001
    )
    #expect(
      abs(
        DashboardReviewDiffTypography.pointSize(fontScale: maximumScale)
          - (DashboardReviewDiffTypography.basePointSize * maximumScale)
      ) < 0.001
    )
  }

  @Test("Detail root applies one scaled body font for default PR-detail text")
  func detailRootAppliesScaledBodyFont() throws {
    let source = try dashboardSource(named: "DashboardReviewDetailView.swift")

    #expect(source.contains("@Environment(\\.fontScale)"))
    #expect(source.contains(".font(HarnessMonitorTextSize.scaledFont(.body, by: fontScale))"))
  }

  @Test("File-card hot path keeps font scale out of environment-driven modifiers")
  func fileCardHotPathKeepsFontScaleOutOfEnvironmentDrivenModifiers() throws {
    let source = try dashboardSource(named: "DashboardReviewFileCard.swift")
    let modifierLines =
      source
      .split(separator: "\n")
      .map(String.init)
      .filter {
        $0.trimmingCharacters(in: .whitespaces).hasPrefix(".scaledFont(")
      }

    #expect(source.contains("let fontScale: CGFloat"))
    #expect(!source.contains("@Environment(\\.fontScale)"))
    #expect(source.contains("HarnessMonitorTextSize.scaledFont("))
    #expect(modifierLines.isEmpty)
  }

  @Test("Diff renderers use centralized review diff typography")
  func diffRenderersUseCentralizedReviewDiffTypography() throws {
    let unified = try dashboardSource(named: "DashboardReviewFileDiffUnified.swift")
    let split = try dashboardSource(named: "DashboardReviewFileDiffSplit.swift")

    #expect(unified.contains("DashboardReviewDiffTypography.font(for: fontScale)"))
    #expect(split.contains("DashboardReviewDiffTypography.font(for: fontScale)"))
    #expect(!unified.contains(".font(.system(size: 12"))
    #expect(!split.contains(".font(.system(size: 12"))
  }

  @Test("Comment composer takes font scale as a plain value")
  func commentComposerUsesPlainFontScaleInput() throws {
    let source = try dashboardSource(named: "DashboardReviewCommentComposer.swift")

    #expect(source.contains("let fontScale: CGFloat"))
    #expect(!source.contains("@Environment(\\.fontScale)"))
    #expect(source.contains("bodyFont = HarnessMonitorTextSize.scaledFont(.body, by: fontScale)"))
  }

  @Test("Image preview caches its byte-count formatter")
  func imagePreviewCachesFormatter() throws {
    let source = try dashboardSource(named: "DashboardReviewFileImagePreview.swift")

    #expect(source.contains("@MainActor private static let byteCountFormatter"))
    #expect(source.contains("private static func humanizedBytes"))
    #expect(!source.contains("private func humanizedBytes"))
  }

  @Test("Conversation chrome equality includes font scale")
  func conversationChromeEqualityIncludesFontScale() throws {
    let source = try dashboardSource(named: "DashboardReviewConversationStatusBar.swift")

    #expect(source.contains("let fontScale: CGFloat"))
    #expect(source.contains("&& lhs.fontScale == rhs.fontScale"))
  }

  private func dashboardSource(named fileName: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let appRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL =
      appRoot
      .appendingPathComponent("Sources/HarnessMonitorUIPreviewable/Views/Dashboard")
      .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
