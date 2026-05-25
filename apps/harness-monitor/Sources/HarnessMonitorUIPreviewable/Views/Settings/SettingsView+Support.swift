import HarnessMonitorKit
import SwiftUI

let settingsDiagnosticsSnapshotWorker = SettingsDiagnosticsSnapshotWorker()

struct SettingsRetainedSectionHost<Content: View>: View, Equatable {
  let section: SettingsSection
  let isSelected: Bool
  let isRestorationSuspended: Bool
  private let content: () -> Content

  init(
    section: SettingsSection,
    isSelected: Bool,
    isRestorationSuspended: Bool,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.section = section
    self.isSelected = isSelected
    self.isRestorationSuspended = isRestorationSuspended
    self.content = content
  }

  var body: some View {
    content()
      .environment(\.settingsScrollRestorationSection, isSelected ? section : nil)
      .environment(\.settingsScrollRestorationSuspended, isRestorationSuspended)
      .harnessMCPElementTrackingEnabled(isSelected)
      .opacity(isSelected ? 1 : 0)
      .allowsHitTesting(isSelected)
      .accessibilityHidden(!isSelected)
  }

  nonisolated static func == (
    lhs: SettingsRetainedSectionHost<Content>,
    rhs: SettingsRetainedSectionHost<Content>
  ) -> Bool {
    lhs.section == rhs.section
      && lhs.isSelected == rhs.isSelected
      && lhs.isRestorationSuspended == rhs.isRestorationSuspended
  }
}

struct SettingsRetainedSectionLayout: Layout {
  let selectedSection: SettingsSection

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    selectedSubview(in: subviews)?.sizeThatFits(proposal) ?? .zero
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    selectedSubview(in: subviews)?.place(
      at: bounds.origin,
      proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
    )
  }

  func explicitAlignment(
    of _: HorizontalAlignment,
    in _: CGRect,
    proposal _: ProposedViewSize,
    subviews _: Subviews,
    cache _: inout ()
  ) -> CGFloat? {
    nil
  }

  func explicitAlignment(
    of _: VerticalAlignment,
    in _: CGRect,
    proposal _: ProposedViewSize,
    subviews _: Subviews,
    cache _: inout ()
  ) -> CGFloat? {
    nil
  }

  private func selectedSubview(in subviews: Subviews) -> LayoutSubview? {
    subviews.first { subview in
      subview[SettingsRetainedSectionKey.self] == selectedSection
    } ?? subviews.first
  }
}

struct SettingsRetainedSectionKey: LayoutValueKey {
  static let defaultValue: SettingsSection? = nil
}

struct SettingsConnectionSnapshot {
  let connectionState: HarnessMonitorStore.ConnectionState
  let isDiagnosticsRefreshInFlight: Bool
  let metrics: ConnectionMetrics
  let events: [ConnectionEvent]

  @MainActor
  init(store: HarnessMonitorStore) {
    connectionState = store.connectionState
    isDiagnosticsRefreshInFlight = store.isDiagnosticsRefreshInFlight
    metrics = store.connectionMetrics
    events = store.connectionEvents
  }
}

struct SettingsGeneralSnapshot: Equatable, Sendable {
  let overview: SettingsGeneralOverviewState
  let liveState: SettingsGeneralLiveState

  @MainActor
  init(store: HarnessMonitorStore) {
    overview = SettingsGeneralOverviewState(store: store)
    liveState = SettingsGeneralLiveState(store: store)
  }
}

/// Thin wrapper that confines `SettingsGeneralOverviewState`'s store reads to
/// its own body, so unrelated store updates do not invalidate `SettingsView`.
struct SettingsGeneralSectionRoot: View {
  let store: HarnessMonitorStore
  let isActive: Bool
  @State private var cachedSnapshot: SettingsGeneralSnapshot?

  var body: some View {
    let activeSnapshot = isActive ? SettingsGeneralSnapshot(store: store) : nil
    Group {
      if isActive {
        if let snapshot = activeSnapshot ?? cachedSnapshot {
          SettingsGeneralSection(
            store: store,
            overview: snapshot.overview,
            liveState: snapshot.liveState
          )
        } else {
          ProgressView("Loading general settings...")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        Color.clear
      }
    }
    .task(id: activeSnapshot) {
      guard let activeSnapshot else { return }
      cachedSnapshot = activeSnapshot
    }
  }
}

/// Thin wrapper that confines connection-snapshot store reads (including the
/// `connectionEvents` array copy) to its own body, so connection telemetry
/// updates only invalidate the connection section, not the whole `SettingsView`.
struct SettingsConnectionSectionRoot: View {
  let store: HarnessMonitorStore
  let isActive: Bool
  @State private var cachedSnapshot: SettingsConnectionSnapshot?

  var body: some View {
    let activeSnapshot = isActive ? SettingsConnectionSnapshot(store: store) : nil
    Group {
      if isActive {
        if let snapshot = activeSnapshot ?? cachedSnapshot {
          SettingsConnectionSection(
            connectionState: snapshot.connectionState,
            isDiagnosticsRefreshInFlight: snapshot.isDiagnosticsRefreshInFlight,
            metrics: snapshot.metrics,
            events: snapshot.events,
            reconnect: { await store.reconnect() },
            refreshDiagnostics: { await store.refreshDiagnostics() }
          )
        } else {
          ProgressView("Loading connection...")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        Color.clear
      }
    }
    .task(id: isActive) {
      guard isActive else { return }
      cachedSnapshot = SettingsConnectionSnapshot(store: store)
    }
  }
}

/// Thin wrapper that confines `SettingsDiagnosticsSnapshotInput`'s store reads
/// (including four array copies) to its own body. The `@State` for the cached
/// snapshot stays on `SettingsView` via `@Binding`, so revisiting the diagnostics
/// section after switching does not flash the loading state.
struct SettingsDiagnosticsSectionRoot: View {
  let store: HarnessMonitorStore
  let isActive: Bool
  @Binding var preparedInput: SettingsDiagnosticsSnapshotInput?
  @Binding var preparedSnapshot: SettingsDiagnosticsSnapshot?

  var body: some View {
    let activeInput = isActive ? SettingsDiagnosticsSnapshotInput(store: store) : nil
    let displayedInput = isActive ? activeInput ?? preparedInput : nil
    Group {
      if isActive {
        if let displayedInput,
          preparedInput == displayedInput,
          let snapshot = preparedSnapshot
        {
          SettingsDiagnosticsSection(
            snapshot: snapshot,
            revealPermissionLog: { runID, path in
              guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              else {
                return .unavailable
              }
              return store.revealAcpPermissionLogInFinder(runID: runID, rawPath: path)
            },
            repairLaunchAgent: { await store.repairLaunchAgent() }
          )
        } else {
          ProgressView("Loading diagnostics...")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        Color.clear
      }
    }
    .task(id: activeInput) {
      guard let input = activeInput else { return }
      guard preparedInput != input else { return }
      let snapshot = await settingsDiagnosticsSnapshotWorker.prepare(input: input)
      guard !Task.isCancelled else { return }
      preparedInput = input
      preparedSnapshot = snapshot
    }
  }
}
