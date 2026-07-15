import AppKit
import SwiftUI

#Preview("CopyableCommandBox - short") {
  CopyableCommandBox(
    command: "harness-bridge start",
    accessibilityIdentifier: "preview-short"
  )
  .padding()
  .frame(width: 600)
}

#Preview("CopyableCommandBox - long") {
  CopyableCommandBox(
    command: "harness-bridge start --capability agent-tui --capability codex",
    accessibilityIdentifier: "preview-long"
  )
  .padding()
  .frame(width: 600)
}
