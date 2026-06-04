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
    #expect(columnsSource.contains("SessionContentDetailSplitView("))
    #expect(columnsSource.contains("contentWidth: contentColumnWidthBinding"))
    #expect(columnsSource.contains("perfOverrideContentWidth: perfContentDividerWidthBinding"))
    #expect(columnsSource.contains("commitContentWidth: commitContentColumnWidth"))
    #expect(splitSource.contains("NSCursor.resizeLeftRight"))
    #expect(splitSource.contains("@State private var liveContentWidth"))
    #expect(splitSource.contains(".accessibilityAdjustableAction"))
    #expect(splitSource.contains(".onMoveCommand"))
  }

  @Test("Session split relies on owned scroll edge surfaces")
  func sessionSplitReliesOnOwnedScrollEdgeSurfaces() throws {
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift"
    )
    let surfaceSource = try previewableSourceFile(
      named: "Views/Sessions/SessionDetailSurface.swift"
    )

    #expect(!columnsSource.contains(".sessionWindowBackgroundExtensionEffect()"))
    #expect(surfaceSource.contains("topScrollEdgeEffect: .soft"))
    #expect(
      !columnsSource.contains(
        """
        SessionContentDetailSplitView(contentWidth: contentColumnWidthBinding) {
                contentColumn
                  .scrollEdgeEffectStyle
        """
      )
    )
    #expect(
      !columnsSource.contains(
        """
              } detail: {
                detailColumn
                  .scrollEdgeEffectStyle
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
    #expect(columnsSource.contains("SessionGeometryWritebackDeferral.nextMainActorTurn()"))
    #expect(columnsSource.contains("Task { @MainActor in"))
    #expect(splitSource.contains("enum SessionGeometryWritebackDeferral"))
    #expect(splitSource.contains("await Task.yield()"))
    #expect(splitSource.contains("deferReclampLiveWidth(availableWidth: newWidth)"))
    #expect(splitSource.contains("SessionGeometryWritebackDeferral.nextMainActorTurn()"))
    #expect(splitSource.contains("commitContentWidth(contentWidth)"))
    #expect(!splitSource.contains(".animation(.easeOut(duration: animationDuration)"))
  }

  @Test("Session split can host an optional route footer")
  func sessionSplitCanHostAnOptionalRouteFooter() throws {
    let splitSource = try previewableSourceFile(
      named: "Views/Sessions/SessionContentDetailSplitView.swift"
    )

    #expect(
      splitSource.contains(
        "struct SessionContentDetailSplitView<Content: View, Detail: View, Footer: View>"))
    #expect(splitSource.contains("private let footer: Footer"))
    #expect(splitSource.contains("@ViewBuilder footer: () -> Footer = { EmptyView() }"))
    #expect(splitSource.contains("VStack(spacing: 0)"))
    #expect(splitSource.contains("footer"))
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
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)

    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
