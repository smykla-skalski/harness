import HarnessMonitorKit
import SwiftUI

struct AgentTuiTerminalOutputView: View {
  let visibleRows: [AgentTuiScreenSnapshot.VisibleRow]

  var body: some View {
    if visibleRows.isEmpty {
      Text("No terminal output yet.")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    } else {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(visibleRows) { row in
          Text(row.text.isEmpty ? " " : row.text)
            .textSelection(.enabled)
        }
      }
    }
  }
}
