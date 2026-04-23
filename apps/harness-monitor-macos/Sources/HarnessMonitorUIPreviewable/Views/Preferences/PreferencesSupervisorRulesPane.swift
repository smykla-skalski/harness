import HarnessMonitorKit
import SwiftData
import SwiftUI

public struct PreferencesSupervisorRulesPane: View {
  let store: HarnessMonitorStore

  private static let persistDebounceDuration: Duration = .milliseconds(500)
  private static let statusDisplayDuration: Duration = .seconds(2)

  @State private var viewModel = PreferencesSupervisorRulesViewModel()
  @State private var persistedRowsByRuleID: [String: PolicyConfigRow] = [:]
  @State private var statusMessages: [String: String] = [:]
  @State private var errorMessages: [String: String] = [:]
  @State private var pendingPersistTasks: [String: Task<Void, Never>] = [:]

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  private var modelContext: ModelContext? {
    store.modelContext
  }

  public var body: some View {
    Form {
      if modelContext == nil {
        Section {
          ContentUnavailableView(
            "Rules unavailable",
            systemImage: "externaldrive.badge.exclamationmark",
            description: Text("Rule overrides require a writable Monitor data store.")
          )
        }
      } else {
        ForEach(viewModel.rules) { rule in
          SupervisorRuleSection(
            rule: rule,
            viewModel: viewModel,
            status: statusMessages[rule.id],
            error: errorMessages[rule.id],
            onCommit: { schedulePersist(for: rule) },
            onReset: { resetRule(rule) }
          )
        }
      }
    }
    .preferencesDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesSupervisorPane("rules"))
    .task { reloadRows() }
    .onDisappear(perform: cancelPendingPersists)
  }

  private func reloadRows() {
    guard let modelContext else {
      persistedRowsByRuleID = [:]
      viewModel.applyRows([])
      return
    }
    do {
      let descriptor = FetchDescriptor<PolicyConfigRow>(sortBy: [SortDescriptor(\.ruleID)])
      let rows = try modelContext.fetch(descriptor)
      persistedRowsByRuleID = Dictionary(uniqueKeysWithValues: rows.map { ($0.ruleID, $0) })
      viewModel.applyRows(rows)
      errorMessages = [:]
    } catch {
      persistedRowsByRuleID = [:]
      viewModel.applyRows([])
      errorMessages = Dictionary(
        uniqueKeysWithValues: viewModel.rules.map { ($0.id, error.localizedDescription) }
      )
    }
  }

  private func persistRule(_ rule: PreferencesSupervisorRuleDescriptor) {
    guard let modelContext else { return }
    cancelPendingPersist(for: rule.id)
    do {
      let row = try viewModel.makePolicyConfigRow(forRuleID: rule.id)
      if let persistedRow = persistedRowsByRuleID[rule.id] {
        persistedRow.enabled = row.enabled
        persistedRow.defaultBehaviorRaw = row.defaultBehaviorRaw
        persistedRow.parametersJSON = row.parametersJSON
        persistedRow.updatedAt = Date()
      } else {
        modelContext.insert(row)
      }
      try modelContext.save()
      reloadRows()
      showTransientStatus("Saved rule override", for: rule.id)
      errorMessages[rule.id] = nil
      Task { await store.refreshSupervisorPolicyOverrides() }
    } catch {
      statusMessages[rule.id] = nil
      errorMessages[rule.id] = error.localizedDescription
    }
  }

  private func schedulePersist(for rule: PreferencesSupervisorRuleDescriptor) {
    cancelPendingPersist(for: rule.id)
    pendingPersistTasks[rule.id] = Task {
      try? await Task.sleep(for: Self.persistDebounceDuration)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        persistRule(rule)
      }
    }
  }

  private func cancelPendingPersist(for ruleID: String) {
    pendingPersistTasks.removeValue(forKey: ruleID)?.cancel()
  }

  private func cancelPendingPersists() {
    for ruleID in pendingPersistTasks.keys {
      cancelPendingPersist(for: ruleID)
    }
  }

  private func resetRule(_ rule: PreferencesSupervisorRuleDescriptor) {
    guard let modelContext else { return }
    cancelPendingPersist(for: rule.id)
    if let persistedRow = persistedRowsByRuleID[rule.id] {
      modelContext.delete(persistedRow)
      do {
        try modelContext.save()
      } catch {
        statusMessages[rule.id] = nil
        errorMessages[rule.id] = error.localizedDescription
        return
      }
    }
    viewModel.resetRule(ruleID: rule.id)
    reloadRows()
    showTransientStatus("Reset to built-in defaults", for: rule.id)
    errorMessages[rule.id] = nil
    Task { await store.refreshSupervisorPolicyOverrides() }
  }

  private func showTransientStatus(_ message: String, for ruleID: String) {
    withAnimation(.easeOut(duration: 0.15)) {
      statusMessages[ruleID] = message
    }
    Task {
      try? await Task.sleep(for: Self.statusDisplayDuration)
      await MainActor.run {
        if statusMessages[ruleID] == message {
          withAnimation(.easeOut(duration: 0.15)) {
            statusMessages[ruleID] = nil
          }
        }
      }
    }
  }
}

#Preview("Supervisor Rules Pane") {
  PreferencesSupervisorRulesPane(store: PreferencesPreviewSupport.makeStore())
    .frame(width: 600, height: 400)
}
