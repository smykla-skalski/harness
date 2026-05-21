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
}
