import HarnessMonitorKit
import SwiftData
import SwiftUI

@MainActor
@Observable
private final class DecisionsWindowRuntime {
  var decisions: [Decision] = []
  var auditEvents: [SupervisorEvent] = []
  var liveTick: DecisionLiveTickSnapshot = .placeholder

  func reload(from store: HarnessMonitorStore?) async {
    guard let store else {
      decisions = []
      auditEvents = []
      liveTick = .placeholder
      return
    }

    let decisionStore = await resolveDecisionStore(from: store)
    guard let decisionStore else {
      decisions = []
      auditEvents = []
      liveTick = .placeholder
      return
    }

    decisions = (try? await decisionStore.openDecisions()) ?? []
    auditEvents = Self.loadAuditEvents(from: store.modelContext)
    liveTick = await store.supervisorLiveTickSnapshot()
  }

  private func resolveDecisionStore(from store: HarnessMonitorStore) async -> DecisionStore? {
    if let decisionStore = store.supervisorDecisionStore {
      return decisionStore
    }

    await store.startSupervisor()
    return store.supervisorDecisionStore
  }

  private static func loadAuditEvents(from modelContext: ModelContext?) -> [SupervisorEvent] {
    guard let modelContext else {
      return []
    }

    do {
      var descriptor = FetchDescriptor<SupervisorEvent>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      descriptor.fetchLimit = 128
      return try modelContext.fetch(descriptor)
    } catch {
      return []
    }
  }
}

public struct DecisionsWindowView: View {
  private let store: HarnessMonitorStore?

  @State private var selection: String?
  @State private var detailTab: DecisionDetailTab = .context
  @State private var runtime = DecisionsWindowRuntime()

  @AppStorage("harness.decisions.inspector.visible")
  private var inspectorVisible: Bool = true

  public init(store: HarnessMonitorStore? = nil) {
    self.store = store
  }

  private var actionHandler: any DecisionActionHandler {
    store?.supervisorDecisionActionHandler() ?? NullDecisionActionHandler()
  }

  private var selectedDecision: Decision? {
    if let selection {
      return runtime.decisions.first(where: { $0.id == selection }) ?? runtime.decisions.first
    }
    return runtime.decisions.first
  }

  private var openDecisionCount: Int { runtime.decisions.count }

  private var criticalDecisionCount: Int {
    runtime.decisions.reduce(into: 0) { count, decision in
      if decision.severityRaw == DecisionSeverity.critical.rawValue {
        count += 1
      }
    }
  }

  private var infoDecisionIDs: [String] {
    runtime.decisions
      .filter { $0.severityRaw == DecisionSeverity.info.rawValue }
      .map(\.id)
  }

  private var criticalDecisionIDs: [String] {
    runtime.decisions
      .filter { $0.severityRaw == DecisionSeverity.critical.rawValue }
      .map(\.id)
  }

  private var navigationSubtitle: String {
    let openLabel = "\(openDecisionCount) open"
    guard criticalDecisionCount > 0 else {
      return openLabel
    }
    return "\(openLabel) · \(criticalDecisionCount) critical"
  }

  private var inspectorToggleLabel: String {
    inspectorVisible ? "Hide Inspector" : "Show Inspector"
  }

  private var sessionObserver: ObserverSummary? {
    store?.selectedSession?.observer
  }

  @ViewBuilder private var detailColumn: some View {
    if let selectedDecision {
      DecisionDetailView(
        decision: selectedDecision,
        handler: actionHandler,
        auditEvents: runtime.auditEvents,
        selectedTab: $detailTab,
        observer: sessionObserver
      )
    } else {
      DecisionDetailView(selectedTab: $detailTab, observer: sessionObserver)
    }
  }

  public var body: some View {
    NavigationSplitView {
      DecisionsSidebar(decisions: runtime.decisions, selection: $selection)
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
    } detail: {
      detailColumn
        .inspector(isPresented: $inspectorVisible) {
          DecisionInspector(
            decision: selectedDecision,
            liveTick: runtime.liveTick
          )
          .inspectorColumnWidth(min: 260, ideal: 320, max: 420)
        }
    }
    .navigationSplitViewStyle(.balanced)
    .navigationTitle("Decisions")
    .navigationSubtitle(navigationSubtitle)
    .toolbar { windowToolbar }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionsWindow)
    .task {
      await reload()
    }
    .task(id: store?.supervisorDecisionRefreshTick ?? -1) {
      await reload()
    }
    .onChange(of: store?.supervisorSelectedDecisionID) { _, requestedID in
      guard let requestedID else {
        return
      }
      selection = requestedID
    }
    .onChange(of: selection) { _, newValue in
      store?.supervisorSelectedDecisionID = newValue
    }
    .onChange(of: store?.supervisorObserverFocusTick ?? 0) { _, _ in
      selection = nil
      store?.supervisorSelectedDecisionID = nil
    }
  }

  @ToolbarContentBuilder private var windowToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      bulkActionsMenu
      inspectorToggleButton
    }
  }

  private var bulkActionsMenu: some View {
    Menu {
      Button("Snooze all critical for 1h") {
        Task { await snoozeAllCritical() }
      }
      .disabled(criticalDecisionIDs.isEmpty)
      .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkSnoozeCritical)

      Button("Dismiss all info") {
        Task { await dismissAllInfo() }
      }
      .disabled(infoDecisionIDs.isEmpty)
      .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkDismissInfo)
    } label: {
      Label("Bulk actions", systemImage: "ellipsis.circle")
    }
    .menuIndicator(.hidden)
    .help("Bulk actions")
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionBulkActions)
  }

  private var inspectorToggleButton: some View {
    Button {
      inspectorVisible.toggle()
    } label: {
      Label(inspectorToggleLabel, systemImage: "sidebar.right")
    }
    .keyboardShortcut("i", modifiers: [.command, .option])
    .help(inspectorToggleLabel)
    .accessibilityIdentifier(HarnessMonitorAccessibility.decisionInspectorToggle)
  }

  private func snoozeAllCritical() async {
    let handler = actionHandler
    let oneHour: TimeInterval = 60 * 60
    for id in criticalDecisionIDs {
      await handler.snooze(decisionID: id, duration: oneHour)
    }
  }

  private func dismissAllInfo() async {
    let handler = actionHandler
    for id in infoDecisionIDs {
      await handler.dismiss(decisionID: id)
    }
  }

  private func reload() async {
    await runtime.reload(from: store)

    if let requestedID = store?.supervisorSelectedDecisionID,
      runtime.decisions.contains(where: { $0.id == requestedID })
    {
      selection = requestedID
      return
    }

    if let selection, runtime.decisions.contains(where: { $0.id == selection }) {
      return
    }

    let firstDecisionID = runtime.decisions.first?.id
    selection = firstDecisionID
    store?.supervisorSelectedDecisionID = firstDecisionID
  }
}

#Preview("Decisions Window — empty") {
  DecisionsWindowView()
    .frame(width: 900, height: 640)
}
