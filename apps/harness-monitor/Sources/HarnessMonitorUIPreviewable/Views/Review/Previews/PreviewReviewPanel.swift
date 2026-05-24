import HarnessMonitorKit
import SwiftUI

#Preview("Review state - awaiting") {
  ReviewStatePanel(task: PreviewFixtures.ReviewFlow.awaitingReviewTask)
    .padding()
    .frame(width: 480)
}

#Preview("Review state - partial claim") {
  ReviewStatePanel(task: PreviewFixtures.ReviewFlow.underReviewPartialClaimTask)
    .padding()
    .frame(width: 480)
}

#Preview("Review state - arbitration imminent") {
  ReviewStatePanel(task: PreviewFixtures.ReviewFlow.arbitrationPendingTask)
    .padding()
    .frame(width: 480)
}

#Preview("Improver task card") {
  ReviewImproverCard(task: PreviewFixtures.ReviewFlow.awaitingReviewTask)
    .padding()
    .frame(width: 360)
}
