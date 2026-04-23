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

  public var body: some View {
    NavigationSplitView {
      DecisionsSidebar(decisions: runtime.decisions, selection: $selection)
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
    } detail: {
      if let selectedDecision {
        DecisionDetailView(
          decision: selectedDecision,
          handler: actionHandler,
          auditEvents: runtime.auditEvents,
          liveTick: runtime.liveTick,
          selectedTab: $detailTab
        )
      } else {
        DecisionDetailView(selectedTab: $detailTab)
      }
    }
    .navigationSplitViewStyle(.balanced)
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
