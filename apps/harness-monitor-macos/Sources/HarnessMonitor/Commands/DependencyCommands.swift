import HarnessMonitorUIPreviewable
import SwiftUI

struct DependencyCommands: Commands {
  @FocusedValue(\.dashboardDependenciesCommands)
  private var dependencyCommands

  var body: some Commands {
    CommandMenu("Dependencies") {
      Button("Approve Selection") {
        dependencyCommands?.approve()
      }
      .keyboardShortcut("a", modifiers: [.command, .option, .shift])
      .disabled(dependencyCommands?.canApprove != true)

      Button("Merge Selection") {
        dependencyCommands?.merge()
      }
      .keyboardShortcut("m", modifiers: [.command, .option, .shift])
      .disabled(dependencyCommands?.canMerge != true)

      Button("Rerun Checks") {
        dependencyCommands?.rerunChecks()
      }
      .keyboardShortcut("r", modifiers: [.command, .option, .shift])
      .disabled(dependencyCommands?.canRerunChecks != true)

      Divider()

      Button("Open Pull Request") {
        dependencyCommands?.openPullRequest()
      }
      .keyboardShortcut("o", modifiers: [.command, .option, .shift])
      .disabled(dependencyCommands?.canOpenPullRequest != true)

      Button("Copy Diagnostics") {
        dependencyCommands?.copyDiagnostics()
      }
      .keyboardShortcut("d", modifiers: [.command, .option, .shift])
      .disabled(dependencyCommands?.canCopyDiagnostics != true)

      Divider()

      Toggle("Failed Checks Only", isOn: failedChecksOnlyBinding)
        .keyboardShortcut("f", modifiers: [.command, .option, .shift])
        .disabled(dependencyCommands == nil)
    }
  }

  private var failedChecksOnlyBinding: Binding<Bool> {
    Binding(
      get: { dependencyCommands?.hasProblemChecksFilter ?? false },
      set: { _ in dependencyCommands?.toggleProblemChecksFilter() }
    )
  }
}
