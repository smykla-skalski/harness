import Foundation
import Testing

struct SessionContentDetailSplitSourceTests {
  @Test("Session window owns the content-detail split UX")
  func sessionWindowOwnsTheContentDetailSplitUX() throws {
    let viewSource = try previewableSourceFile(named: "Views/Sessions/SessionWindowView.swift")
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift"
    )
    let splitSource = try previewableSourceFile(
      named: "Views/Sessions/SessionContentDetailSplitView.swift"
    )

    #expect(viewSource.contains("@SceneStorage(\"session.content-detail.width\")"))
    #expect(viewSource.contains("sessionSurface"))
    #expect(
      columnsSource.contains(
        "SessionContentDetailSplitView(contentWidth: contentColumnWidthBinding)"
      )
    )
    #expect(columnsSource.contains(".navigationSplitViewStyle(.prominentDetail)"))
    #expect(splitSource.contains("NSCursor.resizeLeftRight"))
    #expect(splitSource.contains("@State private var liveContentWidth"))
    #expect(splitSource.contains(".accessibilityAdjustableAction"))
    #expect(splitSource.contains(".onMoveCommand"))
  }

  @Test("Session split uses one stable background extension host")
  func sessionSplitUsesOneStableBackgroundExtensionHost() throws {
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift"
    )

    #expect(
      columnsSource.contains(
        "SessionContentDetailSplitView(contentWidth: contentColumnWidthBinding)"
      )
    )
    #expect(columnsSource.contains("switch renderedRoute.layoutStyle"))
    #expect(columnsSource.contains(".backgroundExtensionEffect()"))
    #expect(
      !columnsSource.contains(
        """
        SessionContentDetailSplitView(contentWidth: contentColumnWidthBinding) {
                contentColumn
                  .backgroundExtensionEffect()
        """
      )
    )
    #expect(
      !columnsSource.contains(
        """
              } detail: {
                detailColumn
                  .backgroundExtensionEffect()
              }
        """
      )
    )
  }

  @Test("Session split layout defers geometry-driven width writes")
  func sessionSplitLayoutDefersGeometryDrivenWidthWrites() throws {
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift"
    )
    let splitSource = try previewableSourceFile(
      named: "Views/Sessions/SessionContentDetailSplitView.swift"
    )

    #expect(columnsSource.contains("deferDetailColumnWidthUpdate("))
    #expect(columnsSource.contains("detailColumnResizeState.cancelPending()"))
    #expect(columnsSource.contains("detailColumnResizeState.settleTask = Task { @MainActor in"))
    #expect(columnsSource.contains("shouldUpdateDetailColumnWidth(to: width)"))
    #expect(splitSource.contains("scheduleSettledGeometryReclamp(availableWidth: newWidth)"))
    #expect(splitSource.contains("resizeState.cancelPending()"))
    #expect(splitSource.contains("resizeState.settleTask = Task { @MainActor in"))
    #expect(
      splitSource.contains(
        "Task.sleep(for: SessionContentDetailSplitLayout.resizeSettleDelay)"
      )
    )
  }

  @Test("Session detail columns leave top padding to the owned views")
  func sessionDetailColumnsLeaveTopPaddingToOwnedViews() throws {
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift"
    )

    #expect(
      !columnsSource.contains(
        """
        contentColumn
                  .padding(.top, HarnessMonitorTheme.spacingLG)
        """
      )
    )
    #expect(
      !columnsSource.contains(
        """
        detailColumn
                  .padding(.top, HarnessMonitorTheme.spacingLG)
        """
      )
    )
    #expect(
      !columnsSource.contains(
        """
        focusModeSurface
                .padding(.top, HarnessMonitorTheme.spacingLG)
        """
      )
    )
  }

  private func previewableSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)

    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
