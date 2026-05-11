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
    #expect(!viewSource.contains(".windowToolbarContentBoundary()"))
    #expect(
      columnsSource.contains(
        "SessionContentDetailSplitView(contentWidth: contentColumnWidth)"
      )
    )
    #expect(columnsSource.contains(".navigationSplitViewStyle(.balanced)"))
    #expect(splitSource.contains("HSplitView"))
    #expect(!splitSource.contains("DragGesture("))
    #expect(!splitSource.contains("NSCursor"))
    #expect(!splitSource.contains("@State"))
    #expect(splitSource.contains("layoutPriority(1)"))
  }

  @Test("Session split uses one stable background extension host")
  func sessionSplitUsesOneStableBackgroundExtensionHost() throws {
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift"
    )
    let surfaceSource = try previewableSourceFile(
      named: "Views/Sessions/SessionDetailSurface.swift"
    )

    #expect(
      columnsSource.contains(
        "SessionContentDetailSplitView(contentWidth: contentColumnWidth)"
      )
    )
    #expect(columnsSource.contains("switch renderedRoute.layoutStyle"))
    #expect(!columnsSource.contains("SessionBackgroundExtensionSurface()"))
    #expect(!surfaceSource.contains("SessionBackgroundExtensionSurface"))
    #expect(!surfaceSource.contains(".backgroundExtensionEffect()"))
    #expect(surfaceSource.contains("topScrollEdgeEffect: .soft"))
    #expect(columnsSource.contains(".backgroundExtensionEffect()"))
    #expect(
      !columnsSource.contains(
        """
        SessionContentDetailSplitView(contentWidth: contentColumnWidth) {
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

  @Test("Session split layout delegates divider resize to native HSplitView")
  func sessionSplitLayoutDelegatesDividerResizeToNativeHSplitView() throws {
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
    #expect(splitSource.contains("HSplitView"))
    #expect(!splitSource.contains("GeometryReader"))
    #expect(!splitSource.contains("resizeState"))
    #expect(!splitSource.contains("Task.sleep"))
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
