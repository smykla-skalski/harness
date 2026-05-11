import Foundation
import Testing

struct ToolbarTitleScalingContractTests {
  @Test("Monitor windows use native navigation titles instead of a custom toolbar title item")
  func monitorWindowsUseNativeNavigationTitles() throws {
    let contentSource = try previewableSourceFile(
      named: "Views/App/ContentViewSupport.swift"
    )
    let sessionChromeSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView.swift"
    )
    let sessionPresentationSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Presentation.swift"
    )
    let sessionRootSource = try appSourceFile(named: "SessionWindowRootView.swift")

    #expect(contentSource.contains(".navigationTitle(navigationTitleText)"))
    #expect(contentSource.contains(".navigationSubtitle(navigationSubtitleText ?? \"\")"))
    #expect(!contentSource.contains("HarnessMonitorToolbarTitleToolbarItem("))
    #expect(sessionPresentationSource.contains("var navigationTitleText: String"))
    #expect(sessionPresentationSource.contains("var navigationSubtitleText: String"))
    #expect(sessionPresentationSource.contains(".navigationTitle(navigationTitleText)"))
    #expect(sessionPresentationSource.contains(".navigationSubtitle(navigationSubtitleText)"))
    #expect(sessionPresentationSource.contains("projectAndWorktreeDisplayLabel(separator: \"·\")"))
    #expect(!sessionChromeSource.contains("HarnessMonitorToolbarTitleToolbarItem("))
    #expect(!sessionRootSource.contains(".navigationTitle(windowTitle)"))
  }

  @Test("Session status lives only in the sidebar footer")
  func sessionStatusLivesOnlyInSidebarFooter() throws {
    let toolbarSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowToolbar.swift"
    )
    let sidebarSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebar.swift"
    )
    let footerSource = try previewableSourceFile(
      named: "Views/Sessions/SessionSidebarFooter.swift"
    )

    #expect(sidebarSource.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
    #expect(sidebarSource.contains("SessionSidebarFooter(model: statusModel)"))
    #expect(footerSource.contains("struct SessionSidebarFooter"))
    #expect(footerSource.contains("SessionStatusStripState"))
    #expect(footerSource.contains("SessionStatusSourceIcon(source: source)"))
    #expect(footerSource.contains("SessionStatusTransportChrome(metrics: metrics)"))
    #expect(footerSource.contains("Spacer(minLength: 0)"))
    #expect(footerSource.contains("SessionStatusStrip("))
    #expect(footerSource.contains("SessionStatusSeparator()"))
    #expect(footerSource.contains("Text(transportLabel)"))
    #expect(footerSource.contains("Text(latencyLabel)"))
    #expect(footerSource.contains("HStack(alignment: .center, spacing: 1)"))
    #expect(
      !footerSource.contains(".scaledFont(.system(.caption2, design: .rounded, weight: .semibold))")
    )
    #expect(footerSource.contains(".padding(.horizontal, footerHorizontalPadding)"))
    #expect(footerSource.contains(".padding(.bottom, footerOuterPadding)"))
    #expect(
      footerSource.contains(
        "RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)"
      )
    )
    #expect(!toolbarSource.contains("SessionToolbarStatusFallback("))
    #expect(!toolbarSource.contains("focusModeStatusModel"))
    #expect(!toolbarSource.contains("SessionToolbarCenterpiece("))
    #expect(!footerSource.contains("Divider()"))
    #expect(!footerSource.contains("HarnessMonitorGlassControlGroup"))
    #expect(!footerSource.contains("harnessFloatingControlGlass"))
    #expect(!footerSource.contains("ConnectionToolbarBadge(metrics: metrics)"))
    #expect(!footerSource.contains("ActivityPulse("))
    #expect(!footerSource.contains("Menu {"))
    #expect(!footerSource.contains(".buttonStyle(.glass)"))
    #expect(!footerSource.contains(".buttonStyle(.glassProminent)"))
  }

  @Test("Connection toolbar badge keeps compact text with the static status dot last")
  func connectionToolbarBadgeKeepsCompactTrailingStatusLayout() throws {
    let connectionSource = try previewableSourceFile(
      named: "Views/App/ConnectionViews.swift"
    )
    let transportRange = try #require(
      connectionSource.range(of: "Text(transportLabel)")
    )
    let pulseRange = try #require(connectionSource.range(of: "ActivityPulse("))

    #expect(transportRange.lowerBound < pulseRange.lowerBound)
    #expect(
      connectionSource.contains(
        "private static let badgeFont = Font.system(.caption2, design: .rounded, weight: .semibold)"
      )
    )
    #expect(connectionSource.contains(".font(Self.badgeFont)"))
    #expect(!connectionSource.contains(".repeatForever(autoreverses: true)"))
    #expect(!connectionSource.contains("@State private var isPulsing"))
    #expect(connectionSource.contains(".animation(.easeOut(duration: 0.3), value: isActive)"))
  }

  @Test("Session focus mode toolbar button uses animated moon symbols")
  func sessionFocusModeToolbarButtonUsesAnimatedMoonSymbols() throws {
    let sessionSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowToolbar.swift"
    )
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift"
    )
    let bannerSource = try previewableSourceFile(
      named: "Views/Sessions/SessionBannerStack.swift"
    )

    #expect(!sessionSource.contains("Toggle(isOn: $focusMode)"))
    #expect(
      sessionSource.contains("Image(systemName: focusMode ? \"moon.fill\" : \"moon\")")
    )
    #expect(sessionSource.contains(".contentTransition("))
    #expect(sessionSource.contains(".replace.magic(fallback: .downUp.wholeSymbol)"))
    #expect(sessionSource.contains("options: .nonRepeating"))
    #expect(sessionSource.contains(".frame(width: 14, height: 14)"))
    #expect(
      sessionSource.contains(".help(focusMode ? \"Exit focus mode\" : \"Enter focus mode\")")
    )
    #expect(sessionSource.contains("toggleFocusMode()"))
    #expect(
      sessionSource.contains(
        "SessionFocusModeMotionPolicy.animation(reduceMotion: reduceMotion)"
      )
    )
    #expect(sessionSource.contains("withAnimation(animation)"))
    #expect(!sessionSource.contains(".animation(.default, value: focusMode)"))
    #expect(
      columnsSource.contains("NavigationSplitView(columnVisibility: columnVisibilityBinding)")
    )
    #expect(columnsSource.contains("if focusMode {\n      focusModeSurface"))
    #expect(
      !columnsSource.contains("SessionFocusModeMotionPolicy.focusedSurfaceTransition")
    )
    #expect(!columnsSource.contains("sidebarMinimumWidth"))
    #expect(!bannerSource.contains("SessionFocusModeMotionPolicy.bannerTransition"))
  }

  @Test("Session window leaves toolbar chrome to tabbing and scene shell")
  func sessionWindowLeavesToolbarChromeToTabbingAndSceneShell() throws {
    let sessionSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView.swift"
    )
    let columnsSource = try previewableSourceFile(
      named: "Views/Sessions/SessionWindowView+Columns.swift"
    )

    #expect(!sessionSource.contains(".suppressToolbarBaselineSeparator()"))
    #expect(
      !columnsSource.contains(".toolbarBackgroundVisibility(.automatic, for: .windowToolbar)")
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

  private func appSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()

    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitor/App")
      .appendingPathComponent(relativePath)

    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
