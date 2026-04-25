import HarnessMonitorKit
import SwiftUI

public struct PreferencesDatabaseSection: View {
  public let store: HarnessMonitorStore
  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  @State private var databaseStats: DatabaseStatistics?
  @State private var isLoadingStats = false
  @State private var pendingConfirmation: DatabaseConfirmation?
  @State private var selectedStatisticsTab: StatisticsTab = .cache

  public var body: some View {
    Form {
      statisticsSection
      operationsSection
      healthSection
    }
    .preferencesDetailFormStyle()
    .task { await refreshStatistics() }
  }

  // MARK: - Statistics

  private var statisticsSection: some View {
    HarnessMonitorTabbedContent(
      title: "Statistics",
      selection: $selectedStatisticsTab,
      tabTitle: \.title,
      alignment: .trailing,
      pickerAccessibilityIdentifier: HarnessMonitorAccessibility
        .preferencesDatabaseStatisticsPicker
    ) { tab in
      switch tab {
      case .cache:
        cacheStatisticsRows
      case .userData:
        userDataStatisticsRows
      case .storage:
        storageStatisticsRows
      }
    }
  }

  @ViewBuilder private var cacheStatisticsRows: some View {
    LabeledContent("Cached Sessions") {
      Text("\(databaseStats?.sessionCount ?? 0)")
        .monospacedDigit()
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesMetricCard("Cached Sessions")
    )
    LabeledContent("Cached Projects") {
      Text("\(databaseStats?.projectCount ?? 0)")
        .monospacedDigit()
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesMetricCard("Cached Projects")
    )
    LabeledContent("Agents") {
      Text("\(databaseStats?.agentCount ?? 0)")
        .monospacedDigit()
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesMetricCard("Agents")
    )
    LabeledContent("Tasks") {
      Text("\(databaseStats?.taskCount ?? 0)")
        .monospacedDigit()
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesMetricCard("Tasks")
    )
    LabeledContent("Signals") {
      Text("\(databaseStats?.signalCount ?? 0)")
        .monospacedDigit()
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesMetricCard("Signals")
    )
    LabeledContent("Timeline Entries") {
      Text("\(databaseStats?.timelineCount ?? 0)")
        .monospacedDigit()
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesMetricCard("Timeline Entries")
    )
  }

  @ViewBuilder private var userDataStatisticsRows: some View {
    LabeledContent("Bookmarks") {
      Text("\(databaseStats?.bookmarkCount ?? 0)")
        .monospacedDigit()
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesMetricCard("Bookmarks")
    )
    LabeledContent("Notes") {
      Text("\(databaseStats?.noteCount ?? 0)")
        .monospacedDigit()
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesMetricCard("Notes")
    )
    LabeledContent("Recent Searches") {
      Text("\(databaseStats?.searchCount ?? 0)")
        .monospacedDigit()
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesMetricCard("Recent Searches")
    )
    LabeledContent("Filter Preferences") {
      Text("\(databaseStats?.filterPreferenceCount ?? 0)")
        .monospacedDigit()
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesMetricCard("Filter Preferences")
    )
  }

  @ViewBuilder private var storageStatisticsRows: some View {
    LabeledContent("App Cache Size") {
      Text(databaseStats?.appCacheSizeFormatted ?? "--")
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesMetricCard("App Cache Size")
    )
    LabeledContent("Daemon DB Size") {
      Text(databaseStats?.daemonDatabaseSizeFormatted ?? "--")
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesMetricCard("Daemon DB Size")
    )
    LabeledContent("Last Cached") {
      Text(databaseStats?.lastCachedFormatted ?? "Never")
    }
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesMetricCard("Last Cached")
    )
  }

  // MARK: - Operations

  private var operationsSection: some View {
    Section {
      HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
        HarnessMonitorWrapLayout(
          spacing: HarnessMonitorTheme.itemSpacing,
          lineSpacing: HarnessMonitorTheme.itemSpacing
        ) {
          HarnessMonitorAsyncActionButton(
            title: "Refresh",
            tint: nil,
            variant: .bordered,
            isLoading: isLoadingStats,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
              "Refresh Statistics"
            ),
            action: { await refreshStatistics() }
          )
          HarnessMonitorActionButton(
            title: "Clear Session Cache",
            tint: .orange,
            variant: .bordered,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
              "Clear Session Cache"
            )
          ) {
            pendingConfirmation = .clearSessionCache
          }
          .popover(
            isPresented: isConfirmationPresented(.clearSessionCache),
            arrowEdge: .top
          ) {
            DatabaseConfirmationPopover(
              confirmation: .clearSessionCache,
              store: store,
              databaseStats: $databaseStats,
              isLoadingStats: $isLoadingStats,
              pendingConfirmation: $pendingConfirmation
            )
          }
          HarnessMonitorAsyncActionButton(
            title: "Clear Search History",
            tint: .secondary,
            variant: .bordered,
            isLoading: isLoadingStats,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
              "Clear Search History"
            ),
            action: {
              store.clearSearchHistory()
              await refreshStatistics()
            }
          )
          HarnessMonitorActionButton(
            title: "Clear User Data",
            tint: .red,
            variant: .bordered,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
              "Clear User Data"
            )
          ) {
            pendingConfirmation = .clearUserData
          }
          .popover(
            isPresented: isConfirmationPresented(.clearUserData),
            arrowEdge: .top
          ) {
            DatabaseConfirmationPopover(
              confirmation: .clearUserData,
              store: store,
              databaseStats: $databaseStats,
              isLoadingStats: $isLoadingStats,
              pendingConfirmation: $pendingConfirmation
            )
          }
          HarnessMonitorActionButton(
            title: "Clear All Data",
            tint: .red,
            variant: .bordered,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
              "Clear All Data"
            )
          ) {
            pendingConfirmation = .clearAllData
          }
          .popover(
            isPresented: isConfirmationPresented(.clearAllData),
            arrowEdge: .top
          ) {
            DatabaseConfirmationPopover(
              confirmation: .clearAllData,
              store: store,
              databaseStats: $databaseStats,
              isLoadingStats: $isLoadingStats,
              pendingConfirmation: $pendingConfirmation
            )
          }
          HarnessMonitorActionButton(
            title: "Reveal in Finder",
            tint: .secondary,
            variant: .bordered,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
              "Reveal in Finder"
            )
          ) {
            store.revealDatabaseInFinder()
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } header: {
      Text("Operations")
    }
  }

  // MARK: - Health

  private var healthSection: some View {
    Section {
      LabeledContent("Persistence") {
        Label(
          store.isPersistenceAvailable ? "Available" : "Error",
          systemImage: store.isPersistenceAvailable
            ? "checkmark.circle.fill" : "xmark.circle.fill"
        )
        .foregroundStyle(
          store.isPersistenceAvailable
            ? HarnessMonitorTheme.success : HarnessMonitorTheme.danger
        )
      }
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.preferencesMetricCard("Persistence")
      )
      if let error = store.persistenceError {
        LabeledContent("Error") {
          Text(error)
            .foregroundStyle(HarnessMonitorTheme.danger)
        }
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.preferencesMetricCard("Persistence Error")
        )
      }
      LabeledContent("Schema Version", value: HarnessMonitorCurrentSchema.versionString)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.preferencesMetricCard("Schema Version")
        )
      HStack {
        Text("Store Path")
        Spacer()
        Text(abbreviateHomePath(databaseStats?.appCacheStorePath ?? "Unavailable"))
          .scaledFont(.caption.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.preferencesMetricCard("Store Path")
      )
      HStack {
        Text("Daemon DB Path")
        Spacer()
        Text(abbreviateHomePath(databaseStats?.daemonDatabasePath ?? "Unavailable"))
          .scaledFont(.caption.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.preferencesMetricCard("Daemon DB Path")
      )
    } header: {
      Text("Health")
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesDatabaseHealth)
  }

  // MARK: - Helpers

  private func refreshStatistics() async {
    isLoadingStats = true
    databaseStats = await store.gatherDatabaseStatistics()
    isLoadingStats = false
  }

  private func isConfirmationPresented(_ confirmation: DatabaseConfirmation) -> Binding<Bool> {
    Binding(
      get: { pendingConfirmation == confirmation },
      set: { isPresented in
        if !isPresented {
          pendingConfirmation = nil
        }
      }
    )
  }
}

#Preview("Preferences Database Section") {
  PreferencesDatabaseSection(
    store: PreferencesPreviewSupport.makeStore()
  )
  .frame(width: 720)
}
