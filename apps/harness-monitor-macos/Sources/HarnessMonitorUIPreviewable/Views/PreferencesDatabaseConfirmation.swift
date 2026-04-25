import HarnessMonitorKit
import SwiftUI

enum DatabaseConfirmation: Equatable {
  case clearSessionCache
  case clearUserData
  case clearAllData

  var promptTitle: String {
    switch self {
    case .clearSessionCache:
      "Clear Session Cache?"
    case .clearUserData:
      "Clear User Data?"
    case .clearAllData:
      "Clear All Data?"
    }
  }

  var actionButtonTitle: String {
    switch self {
    case .clearSessionCache:
      "Clear Session Cache Now"
    case .clearUserData:
      "Clear User Data Now"
    case .clearAllData:
      "Clear All Data Now"
    }
  }

  var message: String {
    switch self {
    case .clearSessionCache:
      "This removes all cached session and project data. Bookmarks, notes, and search history are preserved."
    case .clearUserData:
      "This removes all bookmarks, notes, search history, and filter preferences. "
        + "Cached session data is preserved."
    case .clearAllData:
      "This removes all cached data and user data. This cannot be undone."
    }
  }
}

struct DatabaseConfirmationPopover: View {
  let confirmation: DatabaseConfirmation
  let store: HarnessMonitorStore
  @Binding var databaseStats: DatabaseStatistics?
  @Binding var isLoadingStats: Bool
  @Binding var pendingConfirmation: DatabaseConfirmation?

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(confirmation.promptTitle)
        .scaledFont(.headline)
      Text(confirmation.message)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: HarnessMonitorTheme.itemSpacing) {
        HarnessMonitorActionButton(
          title: confirmation.actionButtonTitle,
          tint: .red,
          variant: .prominent,
          accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
            confirmation.actionButtonTitle
          )
        ) {
          confirm()
        }
        Button("Cancel", role: .cancel) {
          pendingConfirmation = nil
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .keyboardShortcut(.cancelAction)
      }
    }
    .padding(HarnessMonitorTheme.spacingSM)
    .frame(width: 360, alignment: .leading)
  }

  private func confirm() {
    let confirmation = confirmation
    pendingConfirmation = nil

    switch confirmation {
    case .clearSessionCache:
      Task {
        await store.clearSessionCache()
        await refreshStatistics()
      }
    case .clearUserData:
      store.clearAllUserData()
      Task { await refreshStatistics() }
    case .clearAllData:
      Task {
        await store.clearAllDatabaseData()
        await refreshStatistics()
      }
    }
  }

  private func refreshStatistics() async {
    isLoadingStats = true
    databaseStats = await store.gatherDatabaseStatistics()
    isLoadingStats = false
  }
}

enum StatisticsTab: String, CaseIterable, Identifiable {
  case cache
  case userData
  case storage

  var id: String { rawValue }

  var title: String {
    switch self {
    case .cache: "Cache"
    case .userData: "User Data"
    case .storage: "Storage"
    }
  }
}
