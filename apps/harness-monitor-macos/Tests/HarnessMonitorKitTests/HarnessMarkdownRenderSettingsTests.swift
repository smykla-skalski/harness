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
      listItem: 8,
      listItemContent: 9,
      listMarkerGap: 10,
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
    #expect(resolved.spacing.detailsContentIndent == 15)
    #expect(resolved.spacing.listItem == 16)
    #expect(resolved.spacing.listMarkerGap == 20)
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
    #expect(spacing.listMarkerWidth + spacing.listMarkerGap == 26)
    #expect(spacing.listItem == 4)
  }
}
