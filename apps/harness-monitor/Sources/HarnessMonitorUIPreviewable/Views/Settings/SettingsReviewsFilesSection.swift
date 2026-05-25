import HarnessMonitorKit
import SwiftUI

/// Settings panel for the Reviews > Files surface. Edits write
/// through the @Binding draft owned by `SettingsReviewsSection`
/// so the existing Save / Restore Defaults workflow keeps working
/// without per-toggle persistence churn.
struct SettingsReviewsFilesSection: View {
  @Binding var draft: DashboardReviewsPreferences
  @Environment(\.fontScale)
  private var fontScale
  @State private var showsLocalClonesSheet = false
  @State private var generatedPatternInput = ""

  var body: some View {
    Group {
      Toggle("Show file changes", isOn: $draft.filesEnabled)
        .accessibilityIdentifier("settingsReviewFilesEnabledToggle")
      filesLayoutPicker
      Toggle("Soft wrap long lines", isOn: $draft.filesSoftWrapEnabled)
        .accessibilityIdentifier("settingsReviewFilesSoftWrapToggle")
      conversationVisibilityPicker
      autoPrefetchStepper
      autoCollapseStepper
      hideGeneratedToggle
      generatedPatternsEditor
      Toggle("Hide whitespace-only changes", isOn: $draft.filesHideWhitespaceOnly)
      Toggle("Sync viewed state with GitHub", isOn: $draft.filesMarkViewedSyncWithGitHub)
      Toggle("Show inline image previews", isOn: $draft.filesShowImagePreview)
      imagePreviewMaxStepper
      treeDepthStepper
      largeDiffStrategyGroup
      manageClonesButton
      Toggle("Per-line VoiceOver mode", isOn: $draft.filesAccessibilityPerLineMode)
    }
    .sheet(isPresented: $showsLocalClonesSheet) {
      SettingsReviewsLocalClonesSheet()
    }
  }

  private var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  private var generatedPatternsTableRowsHeight: CGFloat {
    let visibleRows = min(draft.filesGeneratedPatterns.count, 8)
    return CGFloat(max(visibleRows, 1)) * 40
  }

  private var tableBackground: some ShapeStyle {
    Color(nsColor: .controlBackgroundColor).opacity(0.42)
  }

  private var normalizedGeneratedPatternInput: String {
    DashboardReviewsPreferences.normalizedGeneratedPattern(generatedPatternInput)
  }

  private var canAddGeneratedPattern: Bool {
    let pattern = normalizedGeneratedPatternInput
    return !pattern.isEmpty && !draft.filesGeneratedPatterns.contains(pattern)
  }

  private var filesLayoutPicker: some View {
    Picker("Files layout", selection: viewModeBinding) {
      ForEach(FilesViewMode.allCases, id: \.self) { mode in
        Text(label(for: mode)).tag(mode)
      }
    }
    .pickerStyle(.menu)
    .help("Default Unified/Split layout used by the Reviews Files list")
    .accessibilityIdentifier("settingsReviewFilesViewModePicker")
  }

  private var conversationVisibilityPicker: some View {
    Picker("Inline conversations", selection: conversationVisibilityBinding) {
      ForEach(ConversationVisibility.allCases, id: \.self) { visibility in
        Text(visibility.menuTitle).tag(visibility)
      }
    }
    .pickerStyle(.menu)
    .help("Default visibility of inline review conversations in the Files diff")
    .accessibilityIdentifier("settingsReviewFilesConversationVisibilityPicker")
  }

  private var hideGeneratedToggle: some View {
    Toggle("Hide generated files", isOn: $draft.filesHideGenerated)
  }

  private var generatedPatternsEditor: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Generated file patterns")
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(
        """
        Patterns use glob syntax (`*`, `?`, `**`). Examples: `package-lock.json`, \
        `**/vendor/**`, `**/*.generated.swift`. Existing legacy regex entries keep \
        matching until you replace them.
        """
      )
      .font(HarnessMonitorTextSize.scaledFont(.caption, by: fontScale))
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .fixedSize(horizontal: false, vertical: true)
      generatedPatternsTable
      generatedPatternsAddRow
    }
  }

  private var generatedPatternsTable: some View {
    VStack(spacing: 0) {
      generatedPatternsTableHeader
      Divider()

      if draft.filesGeneratedPatterns.isEmpty {
        generatedPatternsEmptyRow
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(
              Array(draft.filesGeneratedPatterns.enumerated()), id: \.offset
            ) { index, pattern in
              generatedPatternRow(pattern, index: index)
                .overlay(alignment: .top) {
                  Divider()
                    .opacity(index == 0 ? 0 : 1)
                }
            }
          }
        }
        .frame(height: generatedPatternsTableRowsHeight)
      }
    }
    .background(tableBackground)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsGeneratedPatternsTable)
  }

  private var generatedPatternsTableHeader: some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      Text("Glob pattern")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Action")
        .frame(width: 72, alignment: .trailing)
    }
    .font(captionSemibold)
    .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
  }

  private var generatedPatternsEmptyRow: some View {
    Label("No generated-file patterns configured", systemImage: "wand.and.stars")
      .font(bodyFont)
      .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsGeneratedPatternRow(0))
  }

  private func generatedPatternRow(_ pattern: String, index: Int) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      Text(pattern)
        .font(bodyFont)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button(role: .destructive) {
        draft.removeGeneratedPattern(at: index)
      } label: {
        Image(systemName: "trash")
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(HarnessMonitorTheme.danger)
      .help("Remove \(pattern)")
      .accessibilityLabel("Remove \(pattern)")
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsReviewsGeneratedPatternRemoveButton(index)
      )
      .frame(width: 72, alignment: .trailing)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsGeneratedPatternRow(index))
  }

  private var generatedPatternsAddRow: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      SettingsTaskBoardInboxTextField(
        placeholder: "glob pattern",
        text: $generatedPatternInput,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsReviewsGeneratedPatternField,
        onSubmit: { addGeneratedPattern() }
      )

      Button(
        action: { addGeneratedPattern() },
        label: {
          Label("Add Pattern", systemImage: "plus")
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
        }
      )
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .harnessNativeFormControl()
      .fixedSize(horizontal: true, vertical: true)
      .disabled(!canAddGeneratedPattern)
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsReviewsGeneratedPatternAddButton)

      Button("Restore Defaults") {
        draft.restoreDefaultGeneratedPatterns()
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .harnessNativeFormControl()
      .fixedSize(horizontal: true, vertical: true)
      .disabled(
        draft.filesGeneratedPatterns == DashboardReviewsPreferences.defaultGeneratedPatterns
      )
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsReviewsRestoreDefaultsButton
      )
    }
  }

  private var autoPrefetchStepper: some View {
    Stepper(
      value: $draft.filesAutoPrefetchPatchCap,
      in: 5...100,
      step: 5
    ) {
      Text("Auto-fetch patches for first \(draft.filesAutoPrefetchPatchCap) files")
    }
  }

  private var autoCollapseStepper: some View {
    Stepper(
      value: $draft.filesAutoCollapseHunkLineThreshold,
      in: 100...5_000,
      step: 100
    ) {
      Text("Collapse files larger than \(draft.filesAutoCollapseHunkLineThreshold) lines")
    }
  }

  private var imagePreviewMaxStepper: some View {
    Stepper(value: imagePreviewMaxMBBinding, in: 1...50, step: 1) {
      Text("Image preview max \(draft.filesImagePreviewMaxBytes / 1_048_576) MB")
    }
  }

  private var treeDepthStepper: some View {
    Stepper(
      value: $draft.filesTreeDefaultExpandedDepth,
      in: 1...5
    ) {
      Text("Default tree expanded depth: \(draft.filesTreeDefaultExpandedDepth)")
    }
  }

  private var largeDiffStrategyGroup: some View {
    VStack(alignment: .leading, spacing: 6) {
      Picker("Large PR strategy", selection: strategyBinding) {
        ForEach(FilesLargeDiffStrategy.allCases, id: \.self) { strategy in
          Text(label(for: strategy)).tag(strategy)
        }
      }
      .pickerStyle(.menu)
      Stepper(
        value: $draft.filesLocalCloneThresholdLines,
        in: 100...5_000,
        step: 100
      ) {
        Text("Use local clone above \(draft.filesLocalCloneThresholdLines) line changes")
      }
      .disabled(draft.filesLargeDiffStrategy == .forceGitHubRest)
      Stepper(
        value: $draft.filesLocalCloneDiskBudgetMB,
        in: 512...20_480,
        step: 512
      ) {
        Text("Disk budget for local clones: \(draft.filesLocalCloneDiskBudgetMB) MB")
      }
      Stepper(
        value: $draft.filesLocalCloneMaxAgeDays,
        in: 7...90
      ) {
        Text("Auto-delete clones unused for \(draft.filesLocalCloneMaxAgeDays) days")
      }
    }
  }

  private var manageClonesButton: some View {
    Button("Manage local clones…") {
      showsLocalClonesSheet = true
    }
    .accessibilityIdentifier("settingsReviewFilesManageClonesButton")
  }

  private func addGeneratedPattern() {
    let pattern = normalizedGeneratedPatternInput
    guard !pattern.isEmpty else { return }
    draft.addGeneratedPattern(pattern)
    generatedPatternInput = ""
  }

  // MARK: - Bindings

  private var viewModeBinding: Binding<FilesViewMode> {
    Binding(
      get: { draft.filesDefaultViewMode },
      set: { draft.filesDefaultViewModeRaw = $0.rawValue }
    )
  }

  private var conversationVisibilityBinding: Binding<ConversationVisibility> {
    Binding(
      get: { draft.filesConversationVisibility },
      set: { draft.filesConversationVisibilityRaw = $0.rawValue }
    )
  }

  private var strategyBinding: Binding<FilesLargeDiffStrategy> {
    Binding(
      get: { draft.filesLargeDiffStrategy },
      set: { draft.filesLargeDiffStrategyRaw = $0.rawValue }
    )
  }

  private var imagePreviewMaxMBBinding: Binding<Int> {
    Binding(
      get: { max(1, draft.filesImagePreviewMaxBytes / 1_048_576) },
      set: { draft.filesImagePreviewMaxBytes = $0 * 1_048_576 }
    )
  }

  private func label(for mode: FilesViewMode) -> String {
    switch mode {
    case .unified: return "Unified"
    case .split: return "Split"
    }
  }

  private func label(for strategy: FilesLargeDiffStrategy) -> String {
    switch strategy {
    case .autoLocalClone: return "Use local git clone (recommended)"
    case .forceGitHubRest: return "Always use GitHub REST"
    }
  }
}
