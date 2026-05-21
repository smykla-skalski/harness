import SwiftUI

struct SettingsMarkdownSection: View {
  @AppStorage(HarnessMarkdownUserSettings.storageKey)
  private var storage = HarnessMarkdownUserSettings.defaultStorageValue
  @State private var isFullyExpanded = false

  var body: some View {
    Form {
      scaleSection
      typographySection
      blockSpacingSection
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
    .task { await expandAfterFirstFrame() }
  }

  private func expandAfterFirstFrame() async {
    guard !isFullyExpanded else { return }
    try? await Task.sleep(for: .milliseconds(40))
    isFullyExpanded = true
  }

  private var currentSettings: HarnessMarkdownUserSettings {
    HarnessMarkdownUserSettings.decode(storage)
  }

  private var scaleSection: some View {
    Section {
      Picker("Font scaling", selection: binding(\.scale.mode)) {
        ForEach(HarnessMarkdownScalePreference.allCases) { mode in
          Text(mode.label).tag(mode)
        }
      }
      .harnessNativeFormControl()

      if currentSettings.scale.mode == .custom {
        numberRow("Custom scale", \.scale.customScale, in: 0.5...2, step: 0.05)
      }
    } header: {
      Text("Markdown Rendering")
    } footer: {
      Text("Markdown can follow app text size, use fixed base sizes, or apply a custom scale.")
    }
  }

  private var typographySection: some View {
    Section("Font Sizes") {
      numberRow("Body", \.typography.bodySize, in: 8...28)
      numberRow("Inline code", \.typography.inlineCodeSize, in: 8...28)
      numberRow("Heading 1", \.typography.heading1Size, in: 10...36)
      numberRow("Heading 2", \.typography.heading2Size, in: 10...34)
      numberRow("Heading 3", \.typography.heading3Size, in: 10...32)
      numberRow("Other headings", \.typography.headingDefaultSize, in: 8...28)
      numberRow("Code block text", \.typography.codeSize, in: 8...28)
      numberRow("Code block label", \.typography.codeLabelSize, in: 8...24)
      numberRow("Code block errors", \.typography.codeErrorSize, in: 8...24)
    }
  }

  private var blockSpacingSection: some View {
    Section("Block Gaps") {
      numberRow("Document block gap", \.spacing.documentBlock, in: 0...40)
      numberRow("Paragraph before", \.spacing.paragraphBefore, in: 0...40)
      numberRow("Paragraph after", \.spacing.paragraphAfter, in: 0...40)
      numberRow("Heading before", \.spacing.headingBefore, in: 0...56)
      numberRow("Heading after", \.spacing.headingAfter, in: 0...40)
      numberRow("List before", \.spacing.listBefore, in: 0...40)
      numberRow("List after", \.spacing.listAfter, in: 0...40)
      numberRow("Code block before", \.spacing.codeBlockBefore, in: 0...40)
      numberRow("Code block after", \.spacing.codeBlockAfter, in: 0...40)
      numberRow("Table before", \.spacing.tableBefore, in: 0...40)
      numberRow("Table after", \.spacing.tableAfter, in: 0...40)
      numberRow("Details before", \.spacing.detailsBefore, in: 0...40)
      numberRow("Details after", \.spacing.detailsAfter, in: 0...40)
      numberRow("Quote before", \.spacing.blockQuoteBefore, in: 0...40)
      numberRow("Quote after", \.spacing.blockQuoteAfter, in: 0...40)
      numberRow("Rule before", \.spacing.thematicBreakBefore, in: 0...40)
      numberRow("Rule after", \.spacing.thematicBreakAfter, in: 0...40)
    }
  }

  private var layoutSpacingSection: some View {
    Section("Layout Spacing") {
      numberRow("Nested block gap", \.spacing.nestedBlock, in: 0...32)
      numberRow("Details content indent", \.spacing.detailsContentIndent, in: 0...48)
      numberRow("Details max height", \.spacing.detailsMaxHeight, in: 120...1200)
      numberRow("List item gap", \.spacing.listItem, in: 0...32)
      numberRow("List content gap", \.spacing.listItemContent, in: 0...32)
      numberRow("Marker gap", \.spacing.listMarkerGap, in: 0...32)
      numberRow("Bullet symbol width", \.spacing.listSymbolWidth, in: 0...32)
      numberRow("Ordered and checkbox width", \.spacing.listMarkerWidth, in: 0...48)
      numberRow("Quote content gap", \.spacing.quoteContentGap, in: 0...32)
      numberRow("Table column gap", \.spacing.tableColumn, in: 0...64)
      numberRow("Table row gap", \.spacing.tableRow, in: 0...32)
    }
  }

  private var imageSection: some View {
    Section("Images") {
      numberRow("Inline image height", \.images.maxInlineHeight, in: 8...80)
      numberRow("Block image height", \.images.maxBlockHeight, in: 80...600)
      numberRow("Image corner radius", \.images.cornerRadius, in: 0...24)
    }
  }

  private var markdownColorsSection: some View {
    Section("Markdown Colors") {
      colorRow("Text", \.colors.text)
      colorRow("Secondary text", \.colors.secondaryText)
      colorRow("Links", \.colors.link)
      colorRow("Inline code text", \.colors.inlineCodeText)
      colorRow("Inline code background", \.colors.inlineCodeBackground)
      colorRow("Alert note", \.colors.alertNote)
      colorRow("Alert tip", \.colors.alertTip)
      colorRow("Alert important", \.colors.alertImportant)
      colorRow("Alert warning", \.colors.alertWarning)
      colorRow("Alert caution", \.colors.alertCaution)
      colorRow("Quote bar", \.colors.quoteBar)
      colorRow("Table background", \.colors.tableBackground)
      colorRow("Table border", \.colors.tableBorder)
      colorRow("Checked task", \.colors.taskChecked)
      colorRow("Unchecked task", \.colors.taskUnchecked)
      colorRow("Thematic break", \.colors.thematicBreak)
    }
  }

  private var codeBlockColorsSection: some View {
    Section("Code Block Colors") {
      colorRow("Label", \.code.label)
      colorRow("Error", \.code.error)
      colorRow("Background", \.code.background)
      colorRow("Border", \.code.border)
    }
  }

  private var codeTokenColorsSection: some View {
    Section("Code Token Colors") {
      colorRow("Plain", \.code.tokens.plain)
      colorRow("Comment", \.code.tokens.comment)
      colorRow("Keyword", \.code.tokens.keyword)
      colorRow("String", \.code.tokens.string)
      colorRow("Number", \.code.tokens.number)
      colorRow("Type", \.code.tokens.type)
      colorRow("Property", \.code.tokens.property)
      colorRow("Literal", \.code.tokens.literal)
      colorRow("Operator", \.code.tokens.operatorSymbol)
      colorRow("Punctuation", \.code.tokens.punctuation)
      colorRow("Heading", \.code.tokens.heading)
      colorRow("Inserted", \.code.tokens.inserted)
      colorRow("Deleted", \.code.tokens.deleted)
      colorRow("Whitespace", \.code.tokens.whitespace)
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
        storage = HarnessMarkdownUserSettings.defaultStorageValue
      }
    }
  }

  private func binding<Value>(
    _ keyPath: WritableKeyPath<HarnessMarkdownUserSettings, Value>
  ) -> Binding<Value> {
    Binding {
      currentSettings[keyPath: keyPath]
    } set: { value in
      var next = currentSettings
      next[keyPath: keyPath] = value
      storage = next.storageValue
    }
  }

  private func numberRow(
    _ title: String,
    _ keyPath: WritableKeyPath<HarnessMarkdownUserSettings, Double>,
    in range: ClosedRange<Double>,
    step: Double = 1
  ) -> some View {
    let value = numberBinding(keyPath, in: range)
    return LabeledContent(title) {
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

  private func numberBinding(
    _ keyPath: WritableKeyPath<HarnessMarkdownUserSettings, Double>,
    in range: ClosedRange<Double>
  ) -> Binding<Double> {
    Binding {
      currentSettings[keyPath: keyPath]
    } set: { value in
      var next = currentSettings
      next[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound)
      storage = next.storageValue
    }
  }

  private func colorRow(
    _ title: String,
    _ keyPath: WritableKeyPath<HarnessMarkdownUserSettings, HarnessMarkdownColorChoice>
  ) -> some View {
    Picker(title, selection: binding(keyPath)) {
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
