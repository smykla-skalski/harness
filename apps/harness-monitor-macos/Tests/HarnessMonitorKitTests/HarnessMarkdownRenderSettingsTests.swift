import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Harness markdown render settings")
struct HarnessMarkdownRenderSettingsTests {
  @Test("Font scale modes resolve from environment, explicit, and fixed inputs")
  func fontScaleModesResolveExpectedScale() {
    #expect(
      HarnessMarkdownFontScaleMode.environment.resolvedScale(environmentFontScale: 1.18) == 1.18)
    #expect(
      HarnessMarkdownFontScaleMode.explicit(1.4).resolvedScale(environmentFontScale: 1.18) == 1.4)
    #expect(HarnessMarkdownFontScaleMode.fixed.resolvedScale(environmentFontScale: 1.18) == 1)
    #expect(HarnessMarkdownFontScaleMode.explicit(-2).resolvedScale(environmentFontScale: 1) == 0.1)
  }

  @Test("Markdown typography keeps base sizes and applies configured scale")
  func typographyScalesBaseSizes() {
    let settings = HarnessMarkdownRenderSettings.sized(
      body: 14,
      inlineCode: 12,
      heading1: 22,
      heading2: 18,
      heading3: 16,
      headingDefault: 13,
      fontScaleMode: .explicit(1.25)
    )
    let resolved = settings.resolved(environmentFontScale: 1.8)

    #expect(resolved.typography.body.pointSize == 17.5)
    #expect(resolved.typography.inlineCode.pointSize == 15)
    #expect(resolved.typography.heading1.pointSize == 27.5)
    #expect(resolved.typography.headingDefault.pointSize == 16.25)
  }

  @Test("Code block typography shares markdown font scale mode")
  func codeBlockTypographyUsesMarkdownScaleMode() {
    let codeBlock = HarnessCodeBlockRenderSettings(
      typography: HarnessCodeBlockTypography(
        code: .system(size: 14, design: .monospaced),
        label: .system(size: 10, weight: .semibold),
        error: .system(size: 11, weight: .semibold)
      )
    )
    let settings = HarnessMarkdownRenderSettings(
      codeBlock: codeBlock,
      fontScaleMode: .explicit(1.5)
    )
    let resolvedCode = settings.codeBlock.resolved(environmentFontScale: 1)

    #expect(resolvedCode.typography.code.pointSize == 21)
    #expect(resolvedCode.typography.label.pointSize == 15)
    #expect(resolvedCode.typography.error.pointSize == 16.5)
  }

  @Test("Persisted markdown settings round trip into render settings")
  func persistedMarkdownSettingsRoundTripIntoRenderSettings() {
    var userSettings = HarnessMarkdownUserSettings.default
    userSettings.scale.mode = .custom
    userSettings.scale.customScale = 1.5
    userSettings.typography.bodySize = 14
    userSettings.typography.codeSize = 10
    userSettings.spacing.headingBefore = 12
    userSettings.spacing.listMarkerGap = 3
    userSettings.spacing.detailsMaxHeight = 360
    userSettings.images.maxInlineHeight = 18

    let decoded = HarnessMarkdownUserSettings.decode(userSettings.storageValue)
    let renderSettings = decoded.renderSettings
    let resolved = renderSettings.resolved(environmentFontScale: 1)
    let resolvedCode = renderSettings.codeBlock.resolved(environmentFontScale: 1)

    #expect(decoded == userSettings)
    #expect(resolved.typography.body.pointSize == 21)
    #expect(resolved.spacing.heading.before == 18)
    #expect(resolved.spacing.listMarkerGap == 4.5)
    #expect(resolved.spacing.detailsMaxHeight == 540)
    #expect(resolved.images.maxInlineHeight == 27)
    #expect(resolvedCode.typography.code.pointSize == 15)
  }

  @Test("Persisted markdown spacing keeps defaults for newly added settings")
  func persistedMarkdownSpacingKeepsDefaultsForNewSettings() throws {
    let storage = #"{"documentBlock":12,"listMarkerGap":2}"#
    let decoded = try JSONDecoder().decode(
      HarnessMarkdownUserSettings.Spacing.self,
      from: Data(storage.utf8)
    )

    #expect(decoded.documentBlock == 12)
    #expect(decoded.listMarkerGap == 2)
    #expect(decoded.detailsMaxHeight == 420)
  }

  @Test("Persisted markdown colors keep defaults for newly added settings")
  func persistedMarkdownColorsKeepDefaultsForNewSettings() throws {
    let storage = #"{"text":"secondary","link":"success"}"#
    let decoded = try JSONDecoder().decode(
      HarnessMarkdownUserSettings.Colors.self,
      from: Data(storage.utf8)
    )

    #expect(decoded.text == .secondary)
    #expect(decoded.link == .success)
    #expect(decoded.alertNote == .accent)
    #expect(decoded.alertTip == .success)
    #expect(decoded.alertImportant == .warmAccent)
    #expect(decoded.alertWarning == .caution)
    #expect(decoded.alertCaution == .danger)
  }

  @Test("Markdown spacing settings expose block gaps and scale with font mode")
  func spacingSettingsResolveBlockGaps() {
    let spacing = HarnessMarkdownSpacingSettings(
      documentBlock: 6,
      paragraph: HarnessMarkdownBlockSpacing(before: 1, after: 2),
      heading: HarnessMarkdownBlockSpacing(before: 3, after: 4),
      blockQuote: .none,
      codeBlock: .none,
      details: .none,
      list: HarnessMarkdownBlockSpacing(before: 5, after: 6),
      table: .none,
      thematicBreak: .none,
      nestedBlock: 7,
      detailsContentIndent: 7.5,
      detailsMaxHeight: 300,
      listItem: 8,
      listItemContent: 9,
      listMarkerGap: 10,
      listSymbolWidth: 11,
      listMarkerWidth: 14,
      quoteContentGap: 11,
      tableColumn: 12,
      tableRow: 13
    )
    let settings = HarnessMarkdownRenderSettings(spacing: spacing, fontScaleMode: .explicit(2))
    let resolved = settings.resolved(environmentFontScale: 1)

    #expect(resolved.spacing.documentBlock == 12)
    #expect(resolved.spacing.blockSpacing(for: .paragraph([])).after == 4)
    #expect(resolved.spacing.blockSpacing(for: .heading(level: 1, inlines: [])).before == 6)
    #expect(resolved.spacing.blockSpacing(for: .unorderedList([])).after == 12)
    #expect(
      resolved.spacing.blockSpacing(
        for: .alert(HarnessMarkdownAlert(kind: .note, blocks: []))) == .none)
    #expect(resolved.spacing.detailsContentIndent == 15)
    #expect(resolved.spacing.detailsMaxHeight == 600)
    #expect(resolved.spacing.listItem == 16)
    #expect(resolved.spacing.listMarkerGap == 20)
    #expect(resolved.spacing.listSymbolWidth == 22)
    #expect(resolved.spacing.listMarkerWidth == 28)
    #expect(resolved.spacing.tableColumn == 24)
    #expect(resolved.spacing.tableRow == 26)
  }

  @Test("Default markdown spacing follows PR body typography conventions")
  func defaultMarkdownSpacingFollowsPRBodyTypographyConventions() {
    let spacing = HarnessMarkdownSpacingSettings.default

    #expect(spacing.documentBlock == 8)
    #expect(spacing.heading == HarnessMarkdownBlockSpacing(before: 16, after: 8))
    #expect(spacing.documentBlock + spacing.heading.before == 24)
    #expect(spacing.documentBlock + spacing.heading.after == 16)
    #expect(spacing.detailsMaxHeight == 420)
    #expect(spacing.listSymbolWidth + spacing.listMarkerGap == 12)
    #expect(spacing.listMarkerWidth + spacing.listMarkerGap == 26)
    #expect(spacing.listItem == 4)
  }

  @Test("Settings window exposes markdown renderer controls")
  func settingsWindowExposesMarkdownRendererControls() throws {
    let sidebarSource = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Settings/SettingsSidebar.swift"
    )
    let settingsSource = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Settings/SettingsView.swift"
    )
    let sectionSource = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Settings/SettingsMarkdownSection.swift"
    )
    let rendererSource = try readRepositoryFile(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable"
        + "/Views/Shared/HarnessMonitorMarkdownText.swift"
    )

    #expect(sidebarSource.contains("case markdown"))
    #expect(settingsSource.contains("SettingsMarkdownSection()"))
    #expect(sectionSource.contains("Block Gaps"))
    #expect(sectionSource.contains("Layout Spacing"))
    #expect(sectionSource.contains("Details max height"))
    #expect(sectionSource.contains("Markdown Colors"))
    #expect(sectionSource.contains("Alert note"))
    #expect(sectionSource.contains("Alert caution"))
    #expect(sectionSource.contains("Code Token Colors"))
    #expect(rendererSource.contains("HarnessMarkdownStoredRenderSettings"))
  }

  private func readRepositoryFile(_ relativePath: String) throws -> String {
    try String(contentsOfFile: repositoryPath(relativePath), encoding: .utf8)
  }

  private func repositoryPath(_ relativePath: String) -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(relativePath)
      .path
  }
}
