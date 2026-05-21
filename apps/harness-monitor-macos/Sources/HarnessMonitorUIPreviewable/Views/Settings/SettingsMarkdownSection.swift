import SwiftUI

struct SettingsMarkdownSection: View {
  @AppStorage(HarnessMarkdownUserSettings.storageKey)
  private var storage = HarnessMarkdownUserSettings.defaultStorageValue
  @State private var isFullyExpanded = false

  var body: some View {
    Form {
      MarkdownScaleSection(storage: $storage)
      MarkdownTypographySection(storage: $storage)
      MarkdownBlockSpacingSection(storage: $storage)
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

  private var layoutSpacingSection: some View {
    Section("Layout Spacing") {
      markdownNumberRow("Nested block gap", \.spacing.nestedBlock, storage: $storage, in: 0...32)
      markdownNumberRow(
        "Details content indent", \.spacing.detailsContentIndent, storage: $storage, in: 0...48)
      markdownNumberRow(
        "Details max height", \.spacing.detailsMaxHeight, storage: $storage, in: 120...1200)
      markdownNumberRow("List item gap", \.spacing.listItem, storage: $storage, in: 0...32)
      markdownNumberRow(
        "List content gap", \.spacing.listItemContent, storage: $storage, in: 0...32)
      markdownNumberRow("Marker gap", \.spacing.listMarkerGap, storage: $storage, in: 0...32)
      markdownNumberRow(
        "Bullet symbol width", \.spacing.listSymbolWidth, storage: $storage, in: 0...32)
      markdownNumberRow(
        "Ordered and checkbox width", \.spacing.listMarkerWidth, storage: $storage, in: 0...48)
      markdownNumberRow(
        "Quote content gap", \.spacing.quoteContentGap, storage: $storage, in: 0...32)
      markdownNumberRow(
        "Alert bottom margin", \.spacing.alertBottomMargin, storage: $storage, in: 0...48)
      markdownNumberRow("Table column gap", \.spacing.tableColumn, storage: $storage, in: 0...64)
      markdownNumberRow("Table row gap", \.spacing.tableRow, storage: $storage, in: 0...32)
    }
  }

  private var imageSection: some View {
    Section("Images") {
      markdownNumberRow(
        "Inline image height", \.images.maxInlineHeight, storage: $storage, in: 8...80)
      markdownNumberRow(
        "Block image height", \.images.maxBlockHeight, storage: $storage, in: 80...600)
      markdownNumberRow(
        "Image corner radius", \.images.cornerRadius, storage: $storage, in: 0...24)
    }
  }

  private var markdownColorsSection: some View {
    Section("Markdown Colors") {
      markdownColorRow("Text", \.colors.text, storage: $storage)
      markdownColorRow("Secondary text", \.colors.secondaryText, storage: $storage)
      markdownColorRow("Links", \.colors.link, storage: $storage)
      markdownColorRow("Inline code text", \.colors.inlineCodeText, storage: $storage)
      markdownColorRow("Inline code background", \.colors.inlineCodeBackground, storage: $storage)
      markdownColorRow("Alert note", \.colors.alertNote, storage: $storage)
      markdownColorRow("Alert tip", \.colors.alertTip, storage: $storage)
      markdownColorRow("Alert important", \.colors.alertImportant, storage: $storage)
      markdownColorRow("Alert warning", \.colors.alertWarning, storage: $storage)
      markdownColorRow("Alert caution", \.colors.alertCaution, storage: $storage)
      markdownColorRow("Quote bar", \.colors.quoteBar, storage: $storage)
      markdownColorRow("Table background", \.colors.tableBackground, storage: $storage)
      markdownColorRow("Table border", \.colors.tableBorder, storage: $storage)
      markdownColorRow("Checked task", \.colors.taskChecked, storage: $storage)
      markdownColorRow("Unchecked task", \.colors.taskUnchecked, storage: $storage)
      markdownColorRow("Thematic break", \.colors.thematicBreak, storage: $storage)
    }
  }

  private var codeBlockColorsSection: some View {
    Section("Code Block Colors") {
      markdownColorRow("Label", \.code.label, storage: $storage)
      markdownColorRow("Error", \.code.error, storage: $storage)
      markdownColorRow("Background", \.code.background, storage: $storage)
      markdownColorRow("Border", \.code.border, storage: $storage)
    }
  }

  private var codeTokenColorsSection: some View {
    Section("Code Token Colors") {
      markdownColorRow("Plain", \.code.tokens.plain, storage: $storage)
      markdownColorRow("Comment", \.code.tokens.comment, storage: $storage)
      markdownColorRow("Keyword", \.code.tokens.keyword, storage: $storage)
      markdownColorRow("String", \.code.tokens.string, storage: $storage)
      markdownColorRow("Number", \.code.tokens.number, storage: $storage)
      markdownColorRow("Type", \.code.tokens.type, storage: $storage)
      markdownColorRow("Property", \.code.tokens.property, storage: $storage)
      markdownColorRow("Literal", \.code.tokens.literal, storage: $storage)
      markdownColorRow("Operator", \.code.tokens.operatorSymbol, storage: $storage)
      markdownColorRow("Punctuation", \.code.tokens.punctuation, storage: $storage)
      markdownColorRow("Heading", \.code.tokens.heading, storage: $storage)
      markdownColorRow("Inserted", \.code.tokens.inserted, storage: $storage)
      markdownColorRow("Deleted", \.code.tokens.deleted, storage: $storage)
      markdownColorRow("Whitespace", \.code.tokens.whitespace, storage: $storage)
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
  @Binding var storage: String

  var body: some View {
    Section {
      Picker("Font scaling", selection: markdownBinding(storage: $storage, keyPath: \.scale.mode)) {
        ForEach(HarnessMarkdownScalePreference.allCases) { mode in
          Text(mode.label).tag(mode)
        }
      }
      .harnessNativeFormControl()

      if decodedMarkdown(storage).scale.mode == .custom {
        markdownNumberRow(
          "Custom scale", \.scale.customScale, storage: $storage, in: 0.5...2, step: 0.05)
      }
    } header: {
      Text("Markdown Rendering")
    } footer: {
      Text("Markdown can follow app text size, use fixed base sizes, or apply a custom scale.")
    }
  }
}

private struct MarkdownTypographySection: View {
  @Binding var storage: String

  var body: some View {
    Section("Font Sizes") {
      markdownNumberRow("Body", \.typography.bodySize, storage: $storage, in: 8...28)
      markdownNumberRow("Inline code", \.typography.inlineCodeSize, storage: $storage, in: 8...28)
      markdownNumberRow("Heading 1", \.typography.heading1Size, storage: $storage, in: 10...36)
      markdownNumberRow("Heading 2", \.typography.heading2Size, storage: $storage, in: 10...34)
      markdownNumberRow("Heading 3", \.typography.heading3Size, storage: $storage, in: 10...32)
      markdownNumberRow(
        "Other headings", \.typography.headingDefaultSize, storage: $storage, in: 8...28)
      markdownNumberRow("Code block text", \.typography.codeSize, storage: $storage, in: 8...28)
      markdownNumberRow(
        "Code block label", \.typography.codeLabelSize, storage: $storage, in: 8...24)
      markdownNumberRow(
        "Code block errors", \.typography.codeErrorSize, storage: $storage, in: 8...24)
    }
  }
}

private struct MarkdownBlockSpacingSection: View {
  @Binding var storage: String

  var body: some View {
    Section("Block Gaps") {
      markdownNumberRow(
        "Document block gap", \.spacing.documentBlock, storage: $storage, in: 0...40)
      markdownNumberRow(
        "Paragraph before", \.spacing.paragraphBefore, storage: $storage, in: 0...40)
      markdownNumberRow("Paragraph after", \.spacing.paragraphAfter, storage: $storage, in: 0...40)
      markdownNumberRow("Heading before", \.spacing.headingBefore, storage: $storage, in: 0...56)
      markdownNumberRow("Heading after", \.spacing.headingAfter, storage: $storage, in: 0...40)
      markdownNumberRow("List before", \.spacing.listBefore, storage: $storage, in: 0...40)
      markdownNumberRow("List after", \.spacing.listAfter, storage: $storage, in: 0...40)
      markdownNumberRow(
        "Code block before", \.spacing.codeBlockBefore, storage: $storage, in: 0...40)
      markdownNumberRow(
        "Code block after", \.spacing.codeBlockAfter, storage: $storage, in: 0...40)
      markdownNumberRow("Table before", \.spacing.tableBefore, storage: $storage, in: 0...40)
      markdownNumberRow("Table after", \.spacing.tableAfter, storage: $storage, in: 0...40)
      markdownNumberRow("Details before", \.spacing.detailsBefore, storage: $storage, in: 0...40)
      markdownNumberRow("Details after", \.spacing.detailsAfter, storage: $storage, in: 0...40)
      markdownNumberRow("Quote before", \.spacing.blockQuoteBefore, storage: $storage, in: 0...40)
      markdownNumberRow("Quote after", \.spacing.blockQuoteAfter, storage: $storage, in: 0...40)
      markdownNumberRow(
        "Rule before", \.spacing.thematicBreakBefore, storage: $storage, in: 0...40)
      markdownNumberRow("Rule after", \.spacing.thematicBreakAfter, storage: $storage, in: 0...40)
    }
  }
}

fileprivate func decodedMarkdown(_ storage: String) -> HarnessMarkdownUserSettings {
  HarnessMarkdownUserSettings.decode(storage)
}

fileprivate func markdownBinding<Value>(
  storage: Binding<String>,
  keyPath: WritableKeyPath<HarnessMarkdownUserSettings, Value>
) -> Binding<Value> {
  Binding {
    decodedMarkdown(storage.wrappedValue)[keyPath: keyPath]
  } set: { value in
    var next = decodedMarkdown(storage.wrappedValue)
    next[keyPath: keyPath] = value
    storage.wrappedValue = next.storageValue
  }
}

fileprivate func markdownNumberBinding(
  storage: Binding<String>,
  keyPath: WritableKeyPath<HarnessMarkdownUserSettings, Double>,
  in range: ClosedRange<Double>
) -> Binding<Double> {
  Binding {
    decodedMarkdown(storage.wrappedValue)[keyPath: keyPath]
  } set: { value in
    var next = decodedMarkdown(storage.wrappedValue)
    next[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound)
    storage.wrappedValue = next.storageValue
  }
}

@ViewBuilder
fileprivate func markdownNumberRow(
  _ title: String,
  _ keyPath: WritableKeyPath<HarnessMarkdownUserSettings, Double>,
  storage: Binding<String>,
  in range: ClosedRange<Double>,
  step: Double = 1
) -> some View {
  let value = markdownNumberBinding(storage: storage, keyPath: keyPath, in: range)
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

@ViewBuilder
fileprivate func markdownColorRow(
  _ title: String,
  _ keyPath: WritableKeyPath<HarnessMarkdownUserSettings, HarnessMarkdownColorChoice>,
  storage: Binding<String>
) -> some View {
  Picker(title, selection: markdownBinding(storage: storage, keyPath: keyPath)) {
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
