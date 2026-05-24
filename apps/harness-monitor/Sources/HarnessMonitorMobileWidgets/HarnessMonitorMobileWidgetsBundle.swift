import SwiftUI
import WidgetKit

@main
struct HarnessMonitorMobileWidgetsBundle: WidgetBundle {
  var body: some Widget {
    MobileNeedsYouWidget()
    MobileStationHealthWidget()
    MobileCommandQueueWidget()
    MobileCommandLiveActivity()
  }
}
