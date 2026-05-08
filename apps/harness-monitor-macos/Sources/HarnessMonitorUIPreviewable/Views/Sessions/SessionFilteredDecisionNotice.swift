import AppKit
import SwiftUI

struct SessionFilteredDecisionNotice: View {
  let filters: SessionDecisionFilterState

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "line.3.horizontal.decrease.circle")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Decision hidden by current filters")
          .font(.headline)
        Text("Clear the decision filters to show this selection in the sidebar again.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      Button("Clear Filters") {
        filters.clear()
      }
      .buttonStyle(.glass)
      .tint(.secondary)
      .accessibilityHint("Shows the selected decision in the sidebar again.")
    }
    .padding(12)
    .background {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
  }
}
