import HarnessMonitorKit
import SwiftUI

/// Settings panel for the Reviews > Files surface. Edits write
/// through the @Binding draft owned by `SettingsReviewsSection`
/// so the existing Save / Restore Defaults workflow keeps working
/// without per-toggle persistence churn.
struct SettingsReviewsFilesSection: View {
  @Binding var draft: DashboardReviewsPreferences
  @State private var showsLocalClonesSheet = false

  var body: some View {
    DisclosureGroup("Files") {
      Toggle("Show file changes", isOn: $draft.filesEnabled)
        .accessibilityIdentifier("settingsReviewFilesEnabledToggle")
      defaultViewModePicker
      autoPrefetchStepper
      autoCollapseStepper
      hideGeneratedToggleGroup
      Toggle("Hide whitespace-only changes", isOn: $draft.filesHideWhitespaceOnly)
      Toggle("Sync viewed state with GitHub", isOn: $draft.filesMarkViewedSyncWithGitHub)
      Toggle("Show inline image previews", isOn: $draft.filesShowImagePreview)
      imagePreviewMaxStepper
      treeDepthStepper
      largeDiffStrategyGroup
      manageClonesButton
      Toggle("Per-line VoiceOver mode", isOn: $draft.filesAccessibilityPerLineMode)
    }
    .accessibilityIdentifier("settingsReviewFilesSection")
    .sheet(isPresented: $showsLocalClonesSheet) {
      SettingsReviewsLocalClonesSheet()
    }
  }

  private var defaultViewModePicker: some View {
    Picker("Default view mode", selection: viewModeBinding) {
      ForEach(FilesViewMode.allCases, id: \.self) { mode in
        Text(label(for: mode)).tag(mode)
      }
    }
    .pickerStyle(.menu)
  }

  private var hideGeneratedToggleGroup: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle("Hide generated files", isOn: $draft.filesHideGenerated)
      if draft.filesHideGenerated {
        Text(
          """
          Default patterns hide lock files, vendor/, dist/, *.pb.{go,cc}, and \
          *.generated.{swift,ts,js}. Editing patterns is exposed in advanced settings.
          """
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
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

  // MARK: - Bindings

  private var viewModeBinding: Binding<FilesViewMode> {
    Binding(
      get: { draft.filesDefaultViewMode },
      set: { draft.filesDefaultViewModeRaw = $0.rawValue }
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
