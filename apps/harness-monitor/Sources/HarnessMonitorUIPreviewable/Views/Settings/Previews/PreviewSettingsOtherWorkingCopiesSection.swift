import HarnessMonitorKit
import SwiftUI

#Preview("Other Working Copies Section") {
  Form {
    SettingsOtherWorkingCopiesSection(
      copies: [
        WorkingCopyListEntry(
          repoFullName: "smykla-skalski/harness",
          repoKeySegment: "smykla-skalski__harness",
          path: NSHomeDirectory() + "/Library/Application Support/harness/working-copies/harness",
          sizeBytes: 3_221_225_472,
          createdAt: "2026-06-01T09:00:00Z",
          lastUsedAt: "2026-07-02T11:30:00Z"
        ),
        WorkingCopyListEntry(
          repoFullName: "kumahq/kuma",
          repoKeySegment: "kumahq__kuma",
          path: NSHomeDirectory() + "/Library/Application Support/harness/working-copies/kuma",
          sizeBytes: 412_876_800,
          createdAt: "2026-05-14T08:15:00Z",
          lastUsedAt: "2026-05-20T16:45:00Z"
        ),
      ],
      reclaiming: ["kumahq__kuma"],
      reclaim: { _ in }
    )
  }
  .formStyle(.grouped)
  .frame(width: 720)
}
