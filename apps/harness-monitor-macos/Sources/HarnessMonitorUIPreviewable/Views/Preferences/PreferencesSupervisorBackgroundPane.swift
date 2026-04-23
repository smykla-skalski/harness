import HarnessMonitorKit
import SwiftUI

public struct PreferencesSupervisorBackgroundPane: View {
  public typealias RunInBackgroundHandler = PreferencesSupervisorBackgroundViewModel
    .RunInBackgroundHandler
  public typealias QuietHoursHandler = PreferencesSupervisorBackgroundViewModel.QuietHoursHandler

  @State private var viewModel: PreferencesSupervisorBackgroundViewModel

  public init(
    userDefaults: UserDefaults = .standard,
    onRunInBackgroundChange: @escaping RunInBackgroundHandler = { _ in },
    onQuietHoursChange: @escaping QuietHoursHandler = { _, _ in }
  ) {
    _viewModel = State(
      initialValue: PreferencesSupervisorBackgroundViewModel(
        userDefaults: userDefaults,
        onRunInBackgroundChange: onRunInBackgroundChange,
        onQuietHoursChange: onQuietHoursChange
      )
    )
  }

  public var body: some View {
    Form {
      Section("Background Activity") {
        Toggle(
          "Run supervisor in background",
          isOn: Binding(
            get: { viewModel.runInBackground },
            set: { viewModel.setRunInBackground($0) }
          )
        )
        Text(
          "Keeps the background activity scheduler armed when all Harness Monitor windows are closed."
        )
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        Toggle(
          "Pause automatic actions during quiet hours",
          isOn: Binding(
            get: { viewModel.quietHoursEnabled },
            set: { viewModel.setQuietHoursEnabled($0) }
          )
        )

        if viewModel.quietHoursEnabled {
          DatePicker(
            "From",
            selection: Binding(
              get: { viewModel.quietHoursStart },
              set: { viewModel.setQuietHoursStart($0) }
            ),
            displayedComponents: [.hourAndMinute]
          )
          DatePicker(
            "To",
            selection: Binding(
              get: { viewModel.quietHoursEnd },
              set: { viewModel.setQuietHoursEnd($0) }
            ),
            displayedComponents: [.hourAndMinute]
          )

          Text(
            viewModel.isQuietHoursActive
              ? "Quiet hours are active for the current local time."
              : "Quiet hours are configured but not active right now."
          )
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
        }
      } header: {
        Text("Quiet Hours")
      } footer: {
        Text("Quiet hours use the current local clock and support overnight ranges.")
      }
    }
    .preferencesDetailFormStyle()
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesSupervisorPane("background")
    )
  }
}

#Preview("Supervisor Background Pane") {
  PreferencesSupervisorBackgroundPane()
    .frame(width: 600, height: 400)
}
