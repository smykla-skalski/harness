import HarnessMonitorKit
import SwiftUI

#Preview("Decision Context — empty") {
  DecisionContextPanel()
    .frame(width: 420, height: 320)
}

#Preview("Decision Context — populated") {
  DecisionContextPanel(
    sections: [
      .init(title: "Snapshot", lines: ["agent=agent-7 idle=720s owner=leader"]),
      .init(
        title: "Related timeline",
        lines: ["signal.sent: 12:01", "reminder.sent: 12:04", "reply.missing: 12:12"]
      ),
    ]
  )
  .frame(width: 420, height: 320)
}
