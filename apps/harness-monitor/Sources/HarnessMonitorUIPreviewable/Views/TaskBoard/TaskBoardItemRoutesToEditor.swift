import HarnessMonitorKit
import SwiftUI

/// Loads suggestion list from registered host project types so the chip
/// editor mirrors the orchestrator's routing surface. Local host first,
/// case-insensitive de-duplication, first-seen order preserved.
@MainActor
enum TaskBoardHostProjectTypeSuggestions {
  static func load(from store: HarnessMonitorStore?) async -> [String] {
    guard let store else {
      return []
    }
    do {
      let snapshot = try await store.taskBoardHostSnapshot()
      let hostsInOrder =
        [snapshot.local]
        + snapshot.registered.filter { $0.id != snapshot.local.id }
      var seen = Set<String>()
      var ordered: [String] = []
      for host in hostsInOrder {
        for projectType in host.projectTypes {
          let trimmed = projectType.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { continue }
          if seen.insert(trimmed.lowercased()).inserted {
            ordered.append(trimmed)
          }
        }
      }
      return ordered
    } catch {
      return []
    }
  }
}

/// Chip-style editor for `TaskBoardItem.targetProjectTypes`. Empty list means
/// "route to every host"; non-empty means dispatch only to hosts that declare
/// at least one matching `project_type`. Suggestions come from registered
/// host project types so the picker mirrors the orchestrator's routing
/// surface.
struct TaskBoardItemRoutesToEditor: View {
  @Binding var targetProjectTypes: [String]
  let suggestions: [String]
  let metrics: TaskBoardOverviewMetrics
  let isActionInFlight: Bool

  @State private var draftEntry = ""
  @Environment(\.fontScale)
  private var fontScale

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
  private var caption2Font: Font {
    HarnessMonitorTextSize.scaledFont(.caption2, by: fontScale)
  }
  private var caption2Semibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption2.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      header
      if !targetProjectTypes.isEmpty {
        HarnessMonitorWrapLayout(spacing: HarnessMonitorTheme.spacingXS) {
          ForEach(Array(targetProjectTypes.enumerated()), id: \.offset) { _, projectType in
            projectTypeChip(projectType)
          }
        }
      }
      addRow
      if !suggestionPool.isEmpty {
        suggestionsSection
      }
      Text(
        "Items with no entries route to every host. Add a project type to limit dispatch to "
          + "hosts that declare it"
      )
      .font(caption2Font)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.task-board.manage-item.routes-to")
  }

  private var header: some View {
    HStack {
      Text("Routes To")
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Spacer()
      Text(routingSummary)
        .font(caption2Font)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  private var addRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      HarnessMonitorInlineTextField(
        title: "Add project type",
        text: $draftEntry,
        prompt: "Add project type",
        accessibilityIdentifier: "harness.task-board.manage-item.routes-to.input",
        fieldAlignment: .leading,
        textAlignment: .leading,
        showsClearButton: false
      )
      .onSubmit { commitDraftEntry() }
      Button {
        commitDraftEntry()
      } label: {
        Label("Add", systemImage: "plus")
      }
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .disabled(isActionInFlight || normalizedDraftEntry == nil)
      .accessibilityIdentifier("harness.task-board.manage-item.routes-to.add")
    }
  }

  private var suggestionsSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Suggestions")
        .font(caption2Semibold)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      HarnessMonitorWrapLayout(spacing: HarnessMonitorTheme.spacingXS) {
        ForEach(Array(suggestionPool.enumerated()), id: \.offset) { _, suggestion in
          suggestionChip(suggestion)
        }
      }
    }
  }

  private var routingSummary: String {
    if targetProjectTypes.isEmpty {
      return "any host"
    }
    let suffix = targetProjectTypes.count == 1 ? "" : "s"
    return "\(targetProjectTypes.count) project type\(suffix)"
  }

  private var normalizedDraftEntry: String? {
    let trimmed = draftEntry.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let needle = trimmed.lowercased()
    if targetProjectTypes.contains(where: { $0.lowercased() == needle }) {
      return nil
    }
    return trimmed
  }

  private var suggestionPool: [String] {
    let selected = Set(targetProjectTypes.map { $0.lowercased() })
    return suggestions.filter { !selected.contains($0.lowercased()) }
  }

  private func commitDraftEntry() {
    guard let value = normalizedDraftEntry else { return }
    targetProjectTypes.append(value)
    draftEntry = ""
  }

  private func addSuggestion(_ suggestion: String) {
    let needle = suggestion.lowercased()
    guard !targetProjectTypes.contains(where: { $0.lowercased() == needle }) else { return }
    targetProjectTypes.append(suggestion)
  }

  private func projectTypeChip(_ projectType: String) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      Text(projectType)
        .font(captionSemibold)
        .foregroundStyle(HarnessMonitorTheme.accent)
      Button(role: .destructive) {
        targetProjectTypes.removeAll { $0 == projectType }
      } label: {
        Image(systemName: "xmark.circle.fill")
          .accessibilityHidden(true)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Remove \(projectType)")
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingSM)
    .padding(.vertical, metrics.managementPillVerticalPadding)
    .background(
      HarnessMonitorTheme.accent.opacity(0.12),
      in: .capsule
    )
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("harness.task-board.manage-item.routes-to.chip.\(projectType)")
  }

  private func suggestionChip(_ suggestion: String) -> some View {
    Button {
      addSuggestion(suggestion)
    } label: {
      HStack(spacing: HarnessMonitorTheme.spacingXS) {
        Image(systemName: "plus.circle")
          .accessibilityHidden(true)
        Text(suggestion)
          .font(captionSemibold)
      }
    }
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .disabled(isActionInFlight)
    .accessibilityIdentifier("harness.task-board.manage-item.routes-to.suggestion.\(suggestion)")
  }
}
