import HarnessMonitorKit
import SwiftUI

enum SettingsRepositoryTableMetrics {
  static let disclosureColumnWidth: CGFloat = 24
  static let ownerColumnMinWidth: CGFloat = 120
  static let repositoryColumnMinWidth: CGFloat = 160
  static let publishingColumnWidth: CGFloat = 72
  static let reviewsColumnWidth: CGFloat = 58
  static let actionColumnWidth: CGFloat = 68

  static func minimumWideLayoutWidth(fontScale: CGFloat) -> CGFloat {
    let columnWidths =
      disclosureColumnWidth
      + ownerColumnMinWidth
      + repositoryColumnMinWidth
      + publishingColumnWidth
      + reviewsColumnWidth
      + taskBoardColumnWidth(fontScale: fontScale)
      + actionColumnWidth
    return columnWidths + 8 * HarnessMonitorTheme.spacingMD
  }

  static func taskBoardColumnWidth(fontScale: CGFloat) -> CGFloat {
    68 * max(fontScale, 1)
  }
}

struct SettingsRepositoryTableRow: View {
  @Binding var draft: SettingsSharedRepositoriesDraft
  @Binding var taskBoardDraft: TaskBoardGitSettingsDraft
  @Binding var expandedRows: Set<String>
  let row: SettingsSharedRepositoryRow
  let index: Int
  let overrideCount: Int
  let taskBoardEnabledCount: Int
  let usesWideLayout: Bool

  @Environment(\.fontScale)
  private var fontScale

  private var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
  }

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  private var taskBoardColumnWidth: CGFloat {
    SettingsRepositoryTableMetrics.taskBoardColumnWidth(fontScale: fontScale)
  }

  var body: some View {
    VStack(spacing: 0) {
      repositoryRow
      if expandedRows.contains(row.id) {
        SettingsRepositoryAutomationOverridesPanel(
          repository: row.repositoryPath,
          index: index,
          draft: $taskBoardDraft
        )
      }
    }
    .overlay(alignment: .top) {
      Divider()
        .opacity(index == 0 ? 0 : 1)
    }
  }

  private var repositoryRow: some View {
    Group {
      if usesWideLayout {
        wideRepositoryRow
      } else {
        compactRepositoryRow
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesRow(index))
  }

  private var wideRepositoryRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      disclosureButton
      Text(row.owner)
        .font(bodyFont)
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(
          minWidth: SettingsRepositoryTableMetrics.ownerColumnMinWidth,
          maxWidth: .infinity,
          alignment: .leading
        )
        .layoutPriority(2)
      Text(row.repository)
        .font(bodyFont)
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(
          minWidth: SettingsRepositoryTableMetrics.repositoryColumnMinWidth,
          maxWidth: .infinity,
          alignment: .leading
        )
        .layoutPriority(2)
      publishingSummary
        .frame(
          width: SettingsRepositoryTableMetrics.publishingColumnWidth,
          alignment: .leading
        )
      reviewsToggle
      taskBoardToggle
      rowActions
    }
  }

  private var compactRepositoryRow: some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      disclosureButton
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Text(row.repositoryPath)
          .font(bodyFont)
          .textSelection(.enabled)
          .lineLimit(1)
          .truncationMode(.middle)
        publishingSummary
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .layoutPriority(2)
      reviewsToggle
      taskBoardToggle
      rowActions
    }
  }

  private var publishingSummary: some View {
    Text(publishingSummaryText)
      .font(captionFont)
      .foregroundStyle(
        overrideCount == 0
          ? HarnessMonitorTheme.tertiaryInk : HarnessMonitorTheme.accent
      )
      .lineLimit(1)
  }

  private var reviewsToggle: some View {
    Toggle(
      "Reviews",
      isOn: Binding(
        get: { row.reviewsEnabled },
        set: { draft.setReviewsEnabled($0, for: row.id) }
      )
    )
    .labelsHidden()
    .toggleStyle(.switch)
    .controlSize(.mini)
    .harnessNativeFormControl()
    .frame(minHeight: 24)
    .frame(width: SettingsRepositoryTableMetrics.reviewsColumnWidth, alignment: .center)
    .contentShape(Rectangle())
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.settingsRepositoriesReviewsToggle(index)
    )
  }

  private var taskBoardToggle: some View {
    Toggle(
      "Task Board",
      isOn: Binding(
        get: { row.taskBoardEnabled },
        set: { draft.setTaskBoardEnabled($0, for: row.id) }
      )
    )
    .labelsHidden()
    .toggleStyle(.switch)
    .controlSize(.mini)
    .harnessNativeFormControl()
    .frame(minHeight: 24)
    .frame(width: taskBoardColumnWidth, alignment: .center)
    .contentShape(Rectangle())
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.settingsRepositoriesTaskBoardToggle(index)
    )
  }

  private var rowActions: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Button("Only") {
        draft.enableOnlyForTaskBoard(rowID: row.id)
      }
      .buttonStyle(.borderless)
      .font(captionSemibold)
      .frame(minHeight: 24)
      .contentShape(Rectangle())
      .disabled(row.taskBoardEnabled && taskBoardEnabledCount == 1)
      .help("Use only \(row.repositoryPath) for Task Board")
      .accessibilityLabel("Use only \(row.repositoryPath) for Task Board")
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsRepositoriesTaskBoardOnlyButton(index)
      )

      Button(role: .destructive) {
        expandedRows.remove(row.id)
        draft.remove(rowID: row.id)
      } label: {
        Image(systemName: "trash")
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .foregroundStyle(HarnessMonitorTheme.danger)
      .help("Remove \(row.repositoryPath)")
      .accessibilityLabel("Remove \(row.repositoryPath)")
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsRepositoriesRemoveButton(index)
      )
    }
    .frame(width: SettingsRepositoryTableMetrics.actionColumnWidth, alignment: .trailing)
  }

  private var disclosureButton: some View {
    let isExpanded = expandedRows.contains(row.id)
    return Button {
      if isExpanded {
        expandedRows.remove(row.id)
      } else {
        expandedRows.insert(row.id)
      }
    } label: {
      Image(systemName: "chevron.right")
        .rotationEffect(.degrees(isExpanded ? 90 : 0))
        // The glyph is small, but the target must not be: 24pt is the macOS
        // minimum, and the shape makes the padding around the chevron clickable
        // rather than leaving a hole the pointer can land in.
        .frame(
          width: SettingsRepositoryTableMetrics.disclosureColumnWidth,
          height: SettingsRepositoryTableMetrics.disclosureColumnWidth
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    .help("Publication overrides for \(row.repositoryPath)")
    .accessibilityLabel("Publication overrides for \(row.repositoryPath)")
    .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.settingsRepositoriesOverridesDisclosure(index)
    )
  }

  private var publishingSummaryText: String {
    switch overrideCount {
    case 0: return "Inherited"
    case 1: return "1 override"
    default: return "\(overrideCount) overrides"
    }
  }
}
