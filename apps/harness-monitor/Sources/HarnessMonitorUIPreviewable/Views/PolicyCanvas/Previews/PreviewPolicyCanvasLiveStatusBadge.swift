import SwiftUI

#Preview("Policy canvas live status badge") {
  VStack(alignment: .leading, spacing: 12) {
    PolicyCanvasLiveStatusBadge(status: .live(revision: 7))
    PolicyCanvasLiveStatusBadge(status: .draft(liveRevision: 6))
    PolicyCanvasLiveStatusBadge(status: .draft(liveRevision: nil))
    PolicyCanvasLiveStatusBadge(status: .noPolicy)
  }
  .padding(24)
}
