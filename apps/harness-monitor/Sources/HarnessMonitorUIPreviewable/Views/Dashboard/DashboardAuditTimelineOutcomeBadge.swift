import HarnessMonitorKit
import SwiftUI

struct DashboardAuditOutcomeBadge: View {
  let event: HarnessMonitorAuditEvent

  var body: some View {
    Text(event.outcome.auditDisplayLabel)
      .scaledFont(.caption2)
      .foregroundStyle(event.outcomeTint)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(
        event.outcomeTint.opacity(0.14),
        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
      )
  }
}
