import HarnessMonitorKit
import SwiftUI

public struct SettingsTaskBoardHostSection: View {
  public let store: HarnessMonitorStore

  @State private var snapshot: TaskBoardHostSnapshot?
  @State private var projectTypesText = ""
  @State private var isLoading = false
  @State private var isSaving = false
  @State private var loadError: String?

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  public var body: some View {
    Group {
      if let loadError {
        Section {
          Text(loadError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardHostStatus)
        } header: {
          Text("Host Status")
            .harnessNativeFormSectionHeader()
        }
      } else if isLoading && snapshot == nil {
        Section {
          ProgressView("Loading host settings...")
            .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardHostStatus)
        } header: {
          Text("Host")
            .harnessNativeFormSectionHeader()
        }
      } else if let snapshot {
        localSection(snapshot.local)
        registeredSection(snapshot.registered)
      }
    }
    .task { await loadHost() }
  }

  @ViewBuilder
  private func localSection(_ local: TaskBoardHostMachine) -> some View {
    Section {
      LabeledContent("Host ID", value: local.id)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardHostLocalIdField)
      LabeledContent("Label", value: local.label)
        .accessibilityIdentifier(HarnessMonitorAccessibility.settingsTaskBoardHostLocalLabelField)
      LabeledContent("Last Seen", value: local.lastSeen)
      HarnessMonitorMultilineTextField<Never>(
        placeholder: "project type, one per line (leave empty to clear)",
        text: $projectTypesText,
        minHeight: 66,
        accessibilityLabel: "Host project types"
      )
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.settingsTaskBoardHostProjectTypesField
      )
      HStack {
        HarnessMonitorAsyncActionButton(
          title: "Reload Host",
          tint: .secondary,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardHostReloadButton,
          action: loadHost
        )
        HarnessMonitorAsyncActionButton(
          title: "Save Project Types",
          tint: nil,
          variant: .prominent,
          isLoading: isSaving,
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsTaskBoardHostSaveButton,
          action: saveProjectTypes
        )
        .disabled(loadError != nil)
      }
    } header: {
      Text("Local Host")
        .harnessNativeFormSectionHeader()
    } footer: {
      Text(
        """
        project_types let the orchestrator route task-board items at this host. \
        Leave empty to accept everything. CLI: `harness task-board host set-project-types`.
        """
      )
    }
  }

  @ViewBuilder
  private func registeredSection(_ registered: [TaskBoardHostMachine]) -> some View {
    Section {
      if registered.isEmpty {
        Text("No hosts registered yet.")
      } else {
        ForEach(registered) { machine in
          VStack(alignment: .leading, spacing: 2) {
            Text(machine.label)
              .font(.body.weight(.medium))
            Text(machine.id)
              .font(.caption)
              .foregroundStyle(.secondary)
            if !machine.projectTypes.isEmpty {
              Text("Accepts: \(machine.projectTypes.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
        }
      }
    } header: {
      Text("Registered Hosts")
        .harnessNativeFormSectionHeader()
    }
  }

  @MainActor
  private func loadHost() async {
    isLoading = true
    defer { isLoading = false }

    do {
      let snapshot = try await store.taskBoardHostSnapshot()
      self.snapshot = snapshot
      projectTypesText = snapshot.local.projectTypes.joined(separator: "\n")
      loadError = nil
    } catch {
      loadError = error.localizedDescription
    }
  }

  @MainActor
  private func saveProjectTypes() async {
    isSaving = true
    defer { isSaving = false }

    let projectTypes = normalizedProjectTypes(from: projectTypesText)
    let succeeded = await store.updateTaskBoardHostProjectTypes(projectTypes)
    if succeeded {
      loadError = nil
      await loadHost()
    }
  }

  private func normalizedProjectTypes(from text: String) -> [String] {
    var seen: Set<String> = []
    var entries: [String] = []
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let key = trimmed.lowercased()
      if seen.insert(key).inserted {
        entries.append(trimmed)
      }
    }
    return entries
  }
}
