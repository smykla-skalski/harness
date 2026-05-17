import HarnessMonitorKit
import SwiftUI

public struct SettingsSupervisorRulesPane: View {
  let store: HarnessMonitorStore

  private static let persistDebounceDuration: Duration = .milliseconds(500)
  private static let statusDisplayDuration: Duration = .seconds(2)

  @State private var viewModel = SettingsSupervisorRulesViewModel()
  @State private var persistedRowsByRuleID: [String: PolicyConfigRowSnapshot] = [:]
  @State private var statusMessages: [String: String] = [:]
  @State private var errorMessages: [String: String] = [:]
  @State private var pendingPersistTasks: [String: Task<Void, Never>] = [:]

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  private var repository: SupervisorPolicyConfigRepository? {
    store.supervisorPolicyConfigRepository
  }

  public var body: some View {
    Form {
      if repository == nil {
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
            onReset: { Task { await resetRule(rule) } }
          )
        }
      }
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsSupervisorPane("rules"))
    .task { await reloadRows() }
    .onDisappear(perform: cancelPendingPersists)
  }

  @MainActor
  private func reloadRows() async {
    guard let repository else {
      persistedRowsByRuleID = [:]
      viewModel.applyRowSnapshots([])
      return
    }
    do {
      let rows = try await repository.fetchRows()
      persistedRowsByRuleID = Dictionary(uniqueKeysWithValues: rows.map { ($0.ruleID, $0) })
      viewModel.applyRowSnapshots(rows)
      errorMessages = [:]
    } catch {
      persistedRowsByRuleID = [:]
      viewModel.applyRowSnapshots([])
      errorMessages = Dictionary(
        uniqueKeysWithValues: viewModel.rules.map { ($0.id, error.localizedDescription) }
      )
    }
  }

  @MainActor
  private func persistRule(_ rule: SettingsSupervisorRuleDescriptor) async {
    guard let repository else { return }
    cancelPendingPersist(for: rule.id)
    do {
      let row = try viewModel.makePolicyConfigRowSnapshot(forRuleID: rule.id)
      try await repository.save(row)
      await reloadRows()
      showTransientStatus("Saved rule override", for: rule.id)
      errorMessages[rule.id] = nil
      Task { await store.refreshSupervisorPolicyOverrides() }
    } catch {
      statusMessages[rule.id] = nil
      errorMessages[rule.id] = error.localizedDescription
    }
  }

  private func schedulePersist(for rule: SettingsSupervisorRuleDescriptor) {
    cancelPendingPersist(for: rule.id)
    pendingPersistTasks[rule.id] = Task {
      try? await Task.sleep(for: Self.persistDebounceDuration)
      guard !Task.isCancelled else { return }
      await persistRule(rule)
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

  @MainActor
  private func resetRule(_ rule: SettingsSupervisorRuleDescriptor) async {
    guard let repository else { return }
    cancelPendingPersist(for: rule.id)
    if persistedRowsByRuleID[rule.id] != nil {
      do {
        try await repository.delete(ruleID: rule.id)
      } catch {
        statusMessages[rule.id] = nil
        errorMessages[rule.id] = error.localizedDescription
        return
      }
    }
    viewModel.resetRule(ruleID: rule.id)
    await reloadRows()
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
