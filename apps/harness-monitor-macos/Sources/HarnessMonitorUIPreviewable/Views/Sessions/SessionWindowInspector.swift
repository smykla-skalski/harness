import HarnessMonitorKit
import SwiftUI

struct SessionWindowInspector: View {
  let selection: SessionSelection
  let selectedDecision: Decision?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Inspector")
          .font(.headline)
        Spacer()
      }
      switch selection {
      case .decision:
        if let selectedDecision {
          DecisionDetailSummary(decision: selectedDecision)
        } else {
          ContentUnavailableView("Decision Not Available", systemImage: "exclamationmark.bubble")
        }
      default:
        ContentUnavailableView("No Inspector Context", systemImage: "sidebar.trailing")
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.regularMaterial)
  }
}
