import AppKit
import SwiftUI

private let commandBoxCornerRadius: CGFloat = 6

struct CopyableCommandBox: View {
  let command: String
  let accessibilityIdentifier: String

  @State private var wasCopied = false
  @ScaledMetric(relativeTo: .body)
  private var copyIconSize: CGFloat = 16

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      Text(command)
        .scaledFont(.body.monospaced())
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        HarnessMonitorClipboard.copy(command)
        wasCopied = true
      } label: {
        Image(systemName: wasCopied ? "checkmark" : "doc.on.clipboard")
          .imageScale(.medium)
          .contentTransition(.symbolEffect(.replace))
          .frame(width: copyIconSize, height: copyIconSize)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(
            (wasCopied ? Color.green : Color.secondary).opacity(wasCopied ? 0.25 : 0.18),
            in: RoundedRectangle(cornerRadius: commandBoxCornerRadius, style: .continuous)
          )
          .contentShape(
            RoundedRectangle(cornerRadius: commandBoxCornerRadius, style: .continuous)
          )
      }
      .buttonStyle(.borderless)
      .help(wasCopied ? "Copied" : "Copy command")
      .accessibilityLabel(wasCopied ? "Copied" : "Copy command")
      .accessibilityIdentifier(accessibilityIdentifier)
      .animation(.easeInOut(duration: 0.2), value: wasCopied)
      .task(id: wasCopied) {
        guard wasCopied else { return }
        try? await Task.sleep(for: .seconds(1.5))
        wasCopied = false
      }
    }
    .padding(HarnessMonitorTheme.spacingSM)
    .background(
      .quaternary,
      in: RoundedRectangle(cornerRadius: commandBoxCornerRadius, style: .continuous)
    )
  }
}

#Preview("CopyableCommandBox - short") {
  CopyableCommandBox(
    command: "harness bridge start",
    accessibilityIdentifier: "preview-short"
  )
  .padding()
  .frame(width: 600)
}

#Preview("CopyableCommandBox - long") {
  CopyableCommandBox(
    command: "harness bridge start --capability agent-tui --capability codex",
    accessibilityIdentifier: "preview-long"
  )
  .padding()
  .frame(width: 600)
}
