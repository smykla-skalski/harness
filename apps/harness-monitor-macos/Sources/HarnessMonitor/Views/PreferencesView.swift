import HarnessMonitorKit
import Observation
import SwiftUI

struct PreferencesView: View {
  @Bindable var store: MonitorStore

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Daemon Preferences")
        .font(.system(.largeTitle, design: .serif, weight: .bold))
      GroupBox("Lifecycle") {
        VStack(alignment: .leading, spacing: 12) {
          Text("Launch agent path")
            .font(.headline)
          Text(store.daemonStatus?.launchAgent.path ?? "Unavailable")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
          HStack {
            Button("Start Daemon") {
              Task {
                await store.startDaemon()
              }
            }
            Button("Install Launch Agent") {
              Task {
                await store.installLaunchAgent()
              }
            }
            Button("Remove Launch Agent") {
              Task {
                await store.removeLaunchAgent()
              }
            }
          }
        }
      }
      GroupBox("Health") {
        VStack(alignment: .leading, spacing: 8) {
          Text("Endpoint: \(store.health?.endpoint ?? "Unavailable")")
          Text("Version: \(store.health?.version ?? "Unavailable")")
          Text("Started: \(store.health?.startedAt ?? "Unavailable")")
        }
        .font(.system(.body, design: .rounded))
      }
      Spacer()
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(MonitorTheme.canvas.ignoresSafeArea())
    .foregroundStyle(MonitorTheme.ink)
  }
}
