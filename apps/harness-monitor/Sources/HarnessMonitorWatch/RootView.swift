import HarnessMonitorCore
import SwiftUI

struct RootView: View {
  private let snapshot = MobileDemoFixtures.snapshot()

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            VStack(alignment: .leading) {
              Text("Needs You")
                .font(.headline)
              Text("\(snapshot.stations.count) stations")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(snapshot.needsYouCount)")
              .font(.system(.title, design: .rounded, weight: .bold))
              .foregroundStyle(.red)
              .monospacedDigit()
          }
        }
        Section("Feed") {
          ForEach(snapshot.sortedAttention.prefix(4)) { item in
            VStack(alignment: .leading, spacing: 4) {
              Text(item.title)
                .font(.headline)
              Text(item.kind.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
              if item.commandKind != nil {
                Button {
                } label: {
                  Label("Confirm", systemImage: "checkmark.seal")
                }
              }
            }
          }
        }
        Section("Commands") {
          ForEach(snapshot.commands.prefix(3)) { command in
            HStack {
              Text(command.title)
                .lineLimit(2)
              Spacer()
              Text(command.status.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .navigationTitle("Harness")
    }
  }
}

#Preview {
  RootView()
}
