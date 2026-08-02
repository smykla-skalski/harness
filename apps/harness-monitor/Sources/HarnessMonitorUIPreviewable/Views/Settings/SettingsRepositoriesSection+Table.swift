import HarnessMonitorKit
import SwiftUI

struct RepositoriesMonitoredSection: View {
  @Binding var draft: SettingsSharedRepositoriesDraft
  @Binding var taskBoardDraft: TaskBoardGitSettingsDraft
  @State private var expandedRows: Set<String> = []
  @State private var usesWideTableLayout = false
  @State private var materializedRowCount: Int
  @Environment(\.fontScale)
  private var fontScale

  private var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  init(
    draft: Binding<SettingsSharedRepositoriesDraft>,
    taskBoardDraft: Binding<TaskBoardGitSettingsDraft>,
    initiallyExpandedRows: Set<String> = [],
    initiallyMaterializedRowCount: Int = 6
  ) {
    _draft = draft
    _taskBoardDraft = taskBoardDraft
    _expandedRows = State(initialValue: initiallyExpandedRows)
    _materializedRowCount = State(initialValue: max(0, initiallyMaterializedRowCount))
  }

  private var repositoriesTableViewportHeight: CGFloat {
    let visibleRows = min(draft.rows.count, 8)
    let visibleExpandedRows = draft.rows.prefix(visibleRows).count {
      expandedRows.contains($0.id)
    }
    return CGFloat(visibleRows) * collapsedRowHeight
      + CGFloat(visibleExpandedRows) * expandedPanelHeight
  }

  private var collapsedRowHeight: CGFloat { 44 * fontScale }

  private var expandedPanelHeight: CGFloat { 320 * fontScale }

  private var tableBackground: some ShapeStyle {
    Color(nsColor: .controlBackgroundColor).opacity(0.42)
  }

  var body: some View {
    Section {
      repositoriesTable
      manualAddRow
    } header: {
      Text("Monitored Repositories")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        Manage the shared repository scope for Reviews and Task Board here. Use the switches \
        to control each feature independently, or the delete button to remove a repository. \
        Expand a row to override the publication conventions it inherits from Task Board \
        automation defaults.
        """
      )
    }
  }

  private var repositoriesTable: some View {
    let enabledCount = draft.taskBoardEnabledCount
    let minimumWideLayoutWidth = SettingsRepositoryTableMetrics.minimumWideLayoutWidth(
      fontScale: fontScale
    )
    return VStack(spacing: 0) {
      SettingsRepositoryTaskBoardScopeControls(
        draft: $draft,
        enabledCount: enabledCount
      )
      Divider()
      repositoriesTableHeader
      Divider()

      if draft.rows.isEmpty {
        repositoriesEmptyRow
      } else if draft.rows.count <= 8 {
        VStack(spacing: 0) {
          repositoryRows(enabledCount: enabledCount)
        }
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            repositoryRows(enabledCount: enabledCount)
          }
        }
        .frame(height: repositoriesTableViewportHeight)
      }
    }
    .background(tableBackground)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
    }
    .onGeometryChange(for: Bool.self) { proxy in
      proxy.size.width >= minimumWideLayoutWidth
    } action: { usesWideLayout in
      if usesWideTableLayout != usesWideLayout {
        usesWideTableLayout = usesWideLayout
      }
    }
    .task(id: draft.rows.map(\.id)) {
      await materializeRepositoryRows()
    }
  }

  private var repositoriesTableHeader: some View {
    Group {
      if usesWideTableLayout {
        wideTableHeader
      } else {
        compactTableHeader
      }
    }
    .font(captionSemibold)
    .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
  }

  private func repositoryRows(enabledCount: Int) -> some View {
    ForEach(draft.rows.prefix(min(materializedRowCount, draft.rows.count))) { row in
      let index = draft.index(for: row.id) ?? 0
      let overrideCount = taskBoardDraft.overriddenKinds(for: row.repositoryPath).count
      SettingsRepositoryTableRow(
        draft: $draft,
        taskBoardDraft: $taskBoardDraft,
        expandedRows: $expandedRows,
        row: row,
        index: index,
        overrideCount: overrideCount,
        taskBoardEnabledCount: enabledCount,
        usesWideLayout: usesWideTableLayout
      )
    }
  }

  private func materializeRepositoryRows() async {
    while materializedRowCount < draft.rows.count {
      do {
        try await Task.sleep(for: .milliseconds(8))
      } catch {
        return
      }
      materializedRowCount = min(materializedRowCount + 32, draft.rows.count)
    }
  }

  private var wideTableHeader: some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      Color.clear
        .frame(width: SettingsRepositoryTableMetrics.disclosureColumnWidth, height: 1)
      Text("Owner")
        .lineLimit(1)
        .frame(
          minWidth: SettingsRepositoryTableMetrics.ownerColumnMinWidth,
          maxWidth: .infinity,
          alignment: .leading
        )
        .layoutPriority(2)
      Text("Repository")
        .lineLimit(1)
        .frame(
          minWidth: SettingsRepositoryTableMetrics.repositoryColumnMinWidth,
          maxWidth: .infinity,
          alignment: .leading
        )
        .layoutPriority(2)
      Text("Publishing")
        .lineLimit(1)
        .frame(width: SettingsRepositoryTableMetrics.publishingColumnWidth, alignment: .leading)
      Text("Reviews")
        .lineLimit(1)
        .frame(width: SettingsRepositoryTableMetrics.reviewsColumnWidth, alignment: .center)
      Text("Task Board")
        .lineLimit(1)
        .frame(
          width: SettingsRepositoryTableMetrics.taskBoardColumnWidth(fontScale: fontScale),
          alignment: .center
        )
      Text("Action")
        .lineLimit(1)
        .frame(width: SettingsRepositoryTableMetrics.actionColumnWidth, alignment: .trailing)
    }
  }

  private var compactTableHeader: some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      Color.clear
        .frame(width: SettingsRepositoryTableMetrics.disclosureColumnWidth, height: 1)
      Text("Repository")
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(2)
      Text("Reviews")
        .lineLimit(1)
        .frame(width: SettingsRepositoryTableMetrics.reviewsColumnWidth, alignment: .center)
      Text("Task Board")
        .lineLimit(1)
        .frame(
          width: SettingsRepositoryTableMetrics.taskBoardColumnWidth(fontScale: fontScale),
          alignment: .center
        )
      Text("Action")
        .lineLimit(1)
        .frame(width: SettingsRepositoryTableMetrics.actionColumnWidth, alignment: .trailing)
    }
  }

  private var repositoriesEmptyRow: some View {
    Label("No monitored repositories configured", systemImage: "shippingbox")
      .font(bodyFont)
      .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesRow(0))
  }

  private var manualAddRow: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      SettingsTaskBoardInboxTextField(
        placeholder: "owner",
        text: $draft.ownerInput,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsRepositoriesOwnerField,
        onSubmit: { draft.addManualRepository() }
      )

      SettingsTaskBoardInboxTextField(
        placeholder: "repository",
        text: $draft.repositoryInput,
        accessibilityIdentifier: HarnessMonitorAccessibility.settingsRepositoriesNameField,
        onSubmit: { draft.addManualRepository() }
      )

      Button(
        action: { draft.addManualRepository() },
        label: {
          Label("Add Repository", systemImage: "plus")
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
        }
      )
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
      .harnessNativeFormControl()
      .fixedSize(horizontal: true, vertical: true)
      .disabled(!draft.canAddManualRepository)
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesAddButton)
    }
  }
}
