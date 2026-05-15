import SwiftUI

typealias SessionSidebarRowMetrics = HarnessMonitorSidebarRowMetrics
public typealias SessionSidebarSeverityShape = HarnessMonitorSidebarSeverityShape

struct SessionSidebarRow: View {
  let title: String
  let systemImage: String
  var severityShape: SessionSidebarSeverityShape = .none
  var severityTint: Color = .gray

  var body: some View {
    HarnessMonitorSidebarRow(
      title: title,
      systemImage: systemImage,
      severityShape: severityShape,
      severityTint: severityTint
    )
  }
}
