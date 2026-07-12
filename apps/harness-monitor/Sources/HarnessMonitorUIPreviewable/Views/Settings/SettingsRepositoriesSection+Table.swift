import HarnessMonitorKit
import SwiftUI

struct RepositoriesMonitoredSection: View {
  @Binding var draft: SettingsSharedRepositoriesDraft
  @Environment(\.fontScale)
  private var fontScale

  private var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.body, by: fontScale)
  }

  private var captionSemibold: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  private var repositoriesTableRowsHeight: CGFloat {
    let visibleRows = min(draft.rows.count, 12)
    return CGFloat(visibleRows) * 44
  }

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
        to control each feature independently, or the delete button to remove a repository.
        """
      )
    }
  }

  private var repositoriesTable: some View {
    VStack(spacing: 0) {
      repositoriesTableHeader
      Divider()

      if draft.rows.isEmpty {
        repositoriesEmptyRow
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(draft.rows) { row in
              let index = draft.index(for: row.id) ?? 0
              repositoryTableRow(row, index: index)
            }
          }
        }
        .frame(height: repositoriesTableRowsHeight)
      }
    }
    .background(tableBackground)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
    }
  }

  private func repositoryTableRow(_ row: SettingsSharedRepositoryRow, index: Int) -> some View {
    repositoryRow(row, index: index)
      .overlay(alignment: .top) {
        Divider()
          .opacity(index == 0 ? 0 : 1)
      }
  }

  private var repositoriesTableHeader: some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      Text("Owner")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Repository")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("Reviews")
        .frame(width: 116, alignment: .center)
      Text("Task Board")
        .frame(width: 110, alignment: .center)
      Text("Action")
        .frame(width: 72, alignment: .trailing)
    }
    .font(captionSemibold)
    .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
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

  private func repositoryRow(_ row: SettingsSharedRepositoryRow, index: Int) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      Text(row.owner)
        .font(bodyFont)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(row.repository)
        .font(bodyFont)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Toggle(
        "Reviews",
        isOn: Binding(
          get: { row.reviewsEnabled },
          set: { draft.setReviewsEnabled($0, for: row.id) }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .harnessNativeFormControl()
      .frame(width: 116, alignment: .center)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsRepositoriesReviewsToggle(index)
      )
      Toggle(
        "Task Board",
        isOn: Binding(
          get: { row.taskBoardEnabled },
          set: { draft.setTaskBoardEnabled($0, for: row.id) }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .harnessNativeFormControl()
      .frame(width: 110, alignment: .center)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsRepositoriesTaskBoardToggle(index)
      )
      Button(role: .destructive) {
        draft.remove(rowID: row.id)
      } label: {
        Image(systemName: "trash")
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.borderless)
      .foregroundStyle(HarnessMonitorTheme.danger)
      .help("Remove \(row.repositoryPath)")
      .accessibilityLabel("Remove \(row.repositoryPath)")
      .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesRemoveButton(index))
      .frame(width: 72, alignment: .trailing)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsRepositoriesRow(index))
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
