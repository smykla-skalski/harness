import HarnessMonitorKit
import SwiftUI

struct AgentTuiTerminalOutputView: View {
  let visibleRows: [AgentTuiScreenSnapshot.VisibleRow]
  let terminalSize: AgentTuiSize
  let wrapLines: Bool
  let fontScale: CGFloat

  private var gridWidth: CGFloat? {
    guard !wrapLines else {
      return nil
    }
    return AgentsWindowView.TerminalViewportSizing.contentWidth(
      for: terminalSize,
      fontScale: fontScale
    )
  }

  var body: some View {
    if visibleRows.isEmpty {
      Text("No terminal output yet.")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .frame(
          maxWidth: wrapLines ? .infinity : nil,
          alignment: .leading
        )
    } else {
      LazyVStack(alignment: .leading, spacing: 0) {
        ForEach(visibleRows) { row in
          Text(verbatim: row.text.isEmpty ? " " : row.text)
            .lineLimit(wrapLines ? nil : 1)
            .fixedSize(horizontal: !wrapLines, vertical: wrapLines)
            .frame(
              maxWidth: wrapLines ? .infinity : nil,
              alignment: .leading
            )
            .textSelection(.enabled)
        }
      }
      .frame(
        width: gridWidth,
        alignment: .leading
      )
      .frame(
        maxWidth: wrapLines ? .infinity : nil,
        alignment: .leading
      )
    }
  }
}
