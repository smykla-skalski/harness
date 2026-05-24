import SwiftUI

struct SettingsMarkdownSection: View {
  let isActive: Bool
  @AppStorage(HarnessMarkdownUserSettings.storageKey)
  private var storage = HarnessMarkdownUserSettings.defaultStorageValue
  @State private var storageCache = SettingsMarkdownStorageCache()
  @State private var isFullyExpanded = false

  init(isActive: Bool = true) {
    self.isActive = isActive
  }

  var body: some View {
    if isActive {
      activeBody
    } else {
      Color.clear
    }
  }

  @ViewBuilder private var activeBody: some View {
    let settings = settingsBinding
    Form {
      MarkdownScaleSection(settings: settings)
      MarkdownTypographySection(settings: settings)
      MarkdownBlockSpacingSection(settings: settings)
      if isFullyExpanded {
        layoutSpacingSection
        imageSection
        markdownColorsSection
        codeBlockColorsSection
        codeTokenColorsSection
        previewSection
        resetSection
      }
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsMarkdownSection)
    .task(id: isActive) {
      guard isActive else { return }
      await expandAfterFirstFrame()
    }
  }

  private func expandAfterFirstFrame() async {
    guard !isFullyExpanded else { return }
    try? await Task.sleep(for: .milliseconds(40))
    isFullyExpanded = true
  }

  private var currentSettings: HarnessMarkdownUserSettings {
    storageCache.settings(for: storage)
  }

  private var settingsBinding: Binding<HarnessMarkdownUserSettings> {
    Binding {
      storageCache.settings(for: storage)
    } set: { settings in
      storage = storageCache.storageValue(for: settings)
    }
  }

  private var layoutSpacingSection: some View {
    Section("Layout Spacing") {
      markdownNumberRow(
        "Nested block gap", \.spacing.nestedBlock, settings: settingsBinding, in: 0...32)
      markdownNumberRow(
        "Details content indent", \.spacing.detailsContentIndent, settings: settingsBinding,
        in: 0...48)
      markdownNumberRow(
        "Details max height", \.spacing.detailsMaxHeight, settings: settingsBinding,
        in: 120...1200)
      markdownNumberRow("List item gap", \.spacing.listItem, settings: settingsBinding, in: 0...32)
      markdownNumberRow(
        "List content gap", \.spacing.listItemContent, settings: settingsBinding, in: 0...32)
      markdownNumberRow(
        "Marker gap", \.spacing.listMarkerGap, settings: settingsBinding, in: 0...32)
      markdownNumberRow(
        "Bullet symbol width", \.spacing.listSymbolWidth, settings: settingsBinding, in: 0...32)
      markdownNumberRow(
        "Ordered and checkbox width", \.spacing.listMarkerWidth, settings: settingsBinding,
        in: 0...48)
      markdownNumberRow(
        "Quote content gap", \.spacing.quoteContentGap, settings: settingsBinding, in: 0...32)
      markdownNumberRow(
        "Alert bottom margin", \.spacing.alertBottomMargin, settings: settingsBinding, in: 0...48)
      markdownNumberRow(
        "Table column gap", \.spacing.tableColumn, settings: settingsBinding, in: 0...64)
      markdownNumberRow("Table row gap", \.spacing.tableRow, settings: settingsBinding, in: 0...32)
    }
  }

  private var imageSection: some View {
    Section("Images") {
      markdownNumberRow(
        "Inline image height", \.images.maxInlineHeight, settings: settingsBinding, in: 8...80)
      markdownNumberRow(
        "Block image height", \.images.maxBlockHeight, settings: settingsBinding, in: 80...600)
      markdownNumberRow(
        "Image corner radius", \.images.cornerRadius, settings: settingsBinding, in: 0...24)
    }
  }

  private var markdownColorsSection: some View {
    Section("Markdown Colors") {
      markdownColorRow("Text", \.colors.text, settings: settingsBinding)
      markdownColorRow("Secondary text", \.colors.secondaryText, settings: settingsBinding)
      markdownColorRow("Links", \.colors.link, settings: settingsBinding)
      markdownColorRow("Inline code text", \.colors.inlineCodeText, settings: settingsBinding)
      markdownColorRow(
        "Inline code background", \.colors.inlineCodeBackground, settings: settingsBinding)
      markdownColorRow("Alert note", \.colors.alertNote, settings: settingsBinding)
      markdownColorRow("Alert tip", \.colors.alertTip, settings: settingsBinding)
      markdownColorRow("Alert important", \.colors.alertImportant, settings: settingsBinding)
      markdownColorRow("Alert warning", \.colors.alertWarning, settings: settingsBinding)
      markdownColorRow("Alert caution", \.colors.alertCaution, settings: settingsBinding)
      markdownColorRow("Quote bar", \.colors.quoteBar, settings: settingsBinding)
      markdownColorRow("Table background", \.colors.tableBackground, settings: settingsBinding)
      markdownColorRow("Table border", \.colors.tableBorder, settings: settingsBinding)
      markdownColorRow("Checked task", \.colors.taskChecked, settings: settingsBinding)
      markdownColorRow("Unchecked task", \.colors.taskUnchecked, settings: settingsBinding)
      markdownColorRow("Thematic break", \.colors.thematicBreak, settings: settingsBinding)
    }
  }

  private var codeBlockColorsSection: some View {
    Section("Code Block Colors") {
      markdownColorRow("Label", \.code.label, settings: settingsBinding)
      markdownColorRow("Error", \.code.error, settings: settingsBinding)
      markdownColorRow("Background", \.code.background, settings: settingsBinding)
      markdownColorRow("Border", \.code.border, settings: settingsBinding)
    }
  }

  private var codeTokenColorsSection: some View {
    Section("Code Token Colors") {
      markdownColorRow("Plain", \.code.tokens.plain, settings: settingsBinding)
      markdownColorRow("Comment", \.code.tokens.comment, settings: settingsBinding)
      markdownColorRow("Keyword", \.code.tokens.keyword, settings: settingsBinding)
      markdownColorRow("String", \.code.tokens.string, settings: settingsBinding)
      markdownColorRow("Number", \.code.tokens.number, settings: settingsBinding)
      markdownColorRow("Type", \.code.tokens.type, settings: settingsBinding)
      markdownColorRow("Property", \.code.tokens.property, settings: settingsBinding)
      markdownColorRow("Literal", \.code.tokens.literal, settings: settingsBinding)
      markdownColorRow("Operator", \.code.tokens.operatorSymbol, settings: settingsBinding)
      markdownColorRow("Punctuation", \.code.tokens.punctuation, settings: settingsBinding)
      markdownColorRow("Heading", \.code.tokens.heading, settings: settingsBinding)
      markdownColorRow("Inserted", \.code.tokens.inserted, settings: settingsBinding)
      markdownColorRow("Deleted", \.code.tokens.deleted, settings: settingsBinding)
      markdownColorRow("Whitespace", \.code.tokens.whitespace, settings: settingsBinding)
    }
  }

  private var previewSection: some View {
    Section("Preview") {
      HarnessMonitorMarkdownText(markdownPreview, settings: currentSettings.renderSettings)
        .textSelection(.disabled)
    }
  }

  private var resetSection: some View {
    Section {
      Button("Reset Markdown Rendering") {
        storage = storageCache.storageValue(for: .default)
      }
    }
  }

  private var markdownPreview: String {
    """
    ## Markdown Preview
    - Parent item
      - Nested item
    - [ ] Task item

    > [!NOTE]
    > Note alert

    > [!TIP]
    > Tip alert

    > [!IMPORTANT]
    > Important alert

    > [!WARNING]
    > Warning alert

    > [!CAUTION]
    > Caution alert

    `inline code` and [link](https://example.com)

    ```swift
    let value = "highlight"
    ```
    """
  }
}

private struct MarkdownScaleSection: View {
  @Binding var settings: HarnessMarkdownUserSettings

  var body: some View {
    Section {
      Picker("Font scaling", selection: markdownBinding(settings: $settings, keyPath: \.scale.mode))
      {
        ForEach(HarnessMarkdownScalePreference.allCases) { mode in
          Text(mode.label).tag(mode)
        }
      }
      .harnessNativeFormControl()

      if settings.scale.mode == .custom {
        markdownNumberRow(
          "Custom scale", \.scale.customScale, settings: $settings, in: 0.5...2, step: 0.05)
      }
    } header: {
      Text("Markdown Rendering")
    } footer: {
      Text("Markdown can follow app text size, use fixed base sizes, or apply a custom scale.")
    }
  }
}

private struct MarkdownTypographySection: View {
  @Binding var settings: HarnessMarkdownUserSettings

  var body: some View {
    Section("Font Sizes") {
      markdownNumberRow("Body", \.typography.bodySize, settings: $settings, in: 8...28)
      markdownNumberRow("Inline code", \.typography.inlineCodeSize, settings: $settings, in: 8...28)
      markdownNumberRow("Heading 1", \.typography.heading1Size, settings: $settings, in: 10...36)
      markdownNumberRow("Heading 2", \.typography.heading2Size, settings: $settings, in: 10...34)
      markdownNumberRow("Heading 3", \.typography.heading3Size, settings: $settings, in: 10...32)
      markdownNumberRow(
        "Other headings", \.typography.headingDefaultSize, settings: $settings, in: 8...28)
      markdownNumberRow("Code block text", \.typography.codeSize, settings: $settings, in: 8...28)
      markdownNumberRow(
        "Code block label", \.typography.codeLabelSize, settings: $settings, in: 8...24)
      markdownNumberRow(
        "Code block errors", \.typography.codeErrorSize, settings: $settings, in: 8...24)
    }
  }
}

private struct MarkdownBlockSpacingSection: View {
  @Binding var settings: HarnessMarkdownUserSettings

  var body: some View {
    Section("Block Gaps") {
      markdownNumberRow(
        "Document block gap", \.spacing.documentBlock, settings: $settings, in: 0...40)
      markdownNumberRow(
        "Paragraph before", \.spacing.paragraphBefore, settings: $settings, in: 0...40)
      markdownNumberRow(
        "Paragraph after", \.spacing.paragraphAfter, settings: $settings, in: 0...40)
      markdownNumberRow("Heading before", \.spacing.headingBefore, settings: $settings, in: 0...56)
      markdownNumberRow("Heading after", \.spacing.headingAfter, settings: $settings, in: 0...40)
      markdownNumberRow("List before", \.spacing.listBefore, settings: $settings, in: 0...40)
      markdownNumberRow("List after", \.spacing.listAfter, settings: $settings, in: 0...40)
      markdownNumberRow(
        "Code block before", \.spacing.codeBlockBefore, settings: $settings, in: 0...40)
      markdownNumberRow(
        "Code block after", \.spacing.codeBlockAfter, settings: $settings, in: 0...40)
      markdownNumberRow("Table before", \.spacing.tableBefore, settings: $settings, in: 0...40)
      markdownNumberRow("Table after", \.spacing.tableAfter, settings: $settings, in: 0...40)
      markdownNumberRow("Details before", \.spacing.detailsBefore, settings: $settings, in: 0...40)
      markdownNumberRow("Details after", \.spacing.detailsAfter, settings: $settings, in: 0...40)
      markdownNumberRow("Quote before", \.spacing.blockQuoteBefore, settings: $settings, in: 0...40)
      markdownNumberRow("Quote after", \.spacing.blockQuoteAfter, settings: $settings, in: 0...40)
      markdownNumberRow(
        "Rule before", \.spacing.thematicBreakBefore, settings: $settings, in: 0...40)
      markdownNumberRow("Rule after", \.spacing.thematicBreakAfter, settings: $settings, in: 0...40)
    }
  }
}

@MainActor
private func markdownBinding<Value>(
  settings: Binding<HarnessMarkdownUserSettings>,
  keyPath: WritableKeyPath<HarnessMarkdownUserSettings, Value>
) -> Binding<Value> {
  Binding {
    settings.wrappedValue[keyPath: keyPath]
  } set: { value in
    var next = settings.wrappedValue
    next[keyPath: keyPath] = value
    settings.wrappedValue = next
  }
}

@MainActor
private func markdownNumberBinding(
  settings: Binding<HarnessMarkdownUserSettings>,
  keyPath: WritableKeyPath<HarnessMarkdownUserSettings, Double>,
  in range: ClosedRange<Double>
) -> Binding<Double> {
  Binding {
    settings.wrappedValue[keyPath: keyPath]
  } set: { value in
    var next = settings.wrappedValue
    next[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound)
    settings.wrappedValue = next
  }
}

@MainActor
@ViewBuilder
private func markdownNumberRow(
  _ title: String,
  _ keyPath: WritableKeyPath<HarnessMarkdownUserSettings, Double>,
  settings: Binding<HarnessMarkdownUserSettings>,
  in range: ClosedRange<Double>,
  step: Double = 1
) -> some View {
  let value = markdownNumberBinding(settings: settings, keyPath: keyPath, in: range)
  LabeledContent(title) {
    HStack(spacing: 4) {
      TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .multilineTextAlignment(.trailing)
        .frame(width: 68)
      Stepper("", value: value, in: range, step: step)
        .labelsHidden()
        .controlSize(.small)
    }
  }
}

@MainActor
@ViewBuilder
private func markdownColorRow(
  _ title: String,
  _ keyPath: WritableKeyPath<HarnessMarkdownUserSettings, HarnessMarkdownColorChoice>,
  settings: Binding<HarnessMarkdownUserSettings>
) -> some View {
  Picker(title, selection: markdownBinding(settings: settings, keyPath: keyPath)) {
    ForEach(HarnessMarkdownColorChoice.allCases) { choice in
      HStack {
        Circle()
          .fill(choice.color)
          .frame(width: 10, height: 10)
        Text(choice.label)
      }
      .tag(choice)
    }
  }
  .harnessNativeFormControl()
}

@MainActor
private final class SettingsMarkdownStorageCache {
  private var storage: String?
  private var settings = HarnessMarkdownUserSettings.default

  func settings(for storage: String) -> HarnessMarkdownUserSettings {
    guard self.storage != storage else {
      return settings
    }
    self.storage = storage
    settings = HarnessMarkdownUserSettings.decode(storage)
    return settings
  }

  func storageValue(for settings: HarnessMarkdownUserSettings) -> String {
    let storage = settings.storageValue
    self.storage = storage
    self.settings = settings
    return storage
  }
}
