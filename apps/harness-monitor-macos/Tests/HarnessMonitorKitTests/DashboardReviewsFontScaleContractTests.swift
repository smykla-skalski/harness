import Foundation
import HarnessMonitorKit
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

  @Test("Diff preview reuses highlighted full diff renderers")
  func diffPreviewReusesHighlightedRenderers() throws {
    let preview = try dashboardSource(named: "DashboardReviewFileDiffPreview.swift")

    #expect(preview.contains("DashboardReviewFileDiffUnified("))
    #expect(preview.contains("DashboardReviewFileDiffSplit("))
    #expect(!preview.contains(".font(.system(size: 12"))
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

  @Test("Complete previews do not trigger a full patch fetch")
  func completePreviewsDoNotTriggerFullPatchFetch() {
    #expect(
      !DashboardReviewFileCardInternal.shouldLoadFullPatch(
        previewState: .loaded(preview(hasMore: false)),
        patchState: .notLoaded
      )
    )
  }

  @Test("Truncated previews load the remaining patch in the background")
  func truncatedPreviewsLoadRemainingPatch() {
    #expect(
      DashboardReviewFileCardInternal.shouldLoadFullPatch(
        previewState: .loaded(preview(hasMore: true)),
        patchState: .notLoaded
      )
    )
  }

  @Test("Binary previews still load the full patch payload")
  func binaryPreviewsLoadFullPatchPayload() {
    #expect(
      DashboardReviewFileCardInternal.shouldLoadFullPatch(
        previewState: .loaded(preview(hasMore: false)),
        patchState: .notLoaded,
        isBinary: true
      )
    )
  }

  @Test("Patch state gates duplicate full patch fetches")
  func patchStateGatesDuplicateFetches() {
    #expect(
      !DashboardReviewFileCardInternal.shouldLoadFullPatch(
        previewState: .loaded(preview(hasMore: true)),
        patchState: .loading
      )
    )
    #expect(
      DashboardReviewFileCardInternal.shouldLoadFullPatch(
        previewState: .failed("preview unavailable"),
        patchState: .notLoaded
      )
    )
  }

  private func preview(hasMore: Bool) -> ReviewFilePreview {
    ReviewFilePreview(
      path: "src/file.swift",
      patch: "@@ -1 +1 @@\n-old\n+new\n",
      status: .modified,
      additions: 1,
      deletions: 1,
      fetchedAt: "2026-05-23T12:00:00Z",
      headRefOid: "head-a",
      lineCount: 3,
      lineLimit: 200,
      hasMore: hasMore
    )
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
