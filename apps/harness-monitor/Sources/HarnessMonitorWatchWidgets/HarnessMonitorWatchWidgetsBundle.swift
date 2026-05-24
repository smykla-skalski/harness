import SwiftUI
import WidgetKit

@main
struct HarnessMonitorWatchWidgetsBundle: WidgetBundle {
  var body: some Widget {
    NeedsMeCountWatchWidget()
    WatchNeedsYouWidget()
    WatchStationHealthWidget()
    WatchCommandQueueWidget()
  }
}
