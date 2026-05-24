import Foundation
import HarnessMonitorKit
import SwiftUI

extension TaskBoardItemManagementPanel {
  var routesToEditor: some View {
    TaskBoardItemRoutesToEditor(
      targetProjectTypes: targetProjectTypesBinding,
      suggestions: projectTypeSuggestionValues,
      metrics: metrics,
      isActionInFlight: isActionInFlight
    )
  }

  var externalRefsEditor: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack {
        Text("External Refs")
          .font(panelCaptionSemibold)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Spacer()
        Button {
          appendExternalRefDraft()
        } label: {
          Label("Add Ref", systemImage: "plus")
            .font(panelCaptionSemibold)
        }
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .disabled(isActionInFlight)
      }
      ForEach(visibleExternalRefIDs, id: \.self) { refID in
        externalRefEditorRow(refID: refID)
      }
    }
  }

  var externalDestinations: [TaskBoardExternalDestination] {
    var destinations = visibleExternalRefs.compactMap(externalDestination)
    if let prUrl = item?.workflow?.prUrl, let url = URL(string: prUrl) {
      destinations.append(TaskBoardExternalDestination(label: "Pull Request", url: url))
    }
    return destinations
  }

  @ViewBuilder
  func externalRefEditorRow(refID: UUID) -> some View {
    if let ref = externalRefBinding(for: refID) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
        TaskBoardManagementReadOnlyField(
          label: "Provider",
          value: ref.wrappedValue.provider.title
        )
        TaskBoardManagementNativeField(label: "External ID", text: ref.externalId)
        TaskBoardManagementNativeField(label: "URL", text: ref.url)
        Button(role: .destructive) {
          removeExternalRefDraft(id: ref.wrappedValue.id)
        } label: {
          Image(systemName: "trash")
            .accessibilityHidden(true)
        }
        .buttonStyle(.borderless)
        .frame(minWidth: metrics.iconControlMinWidth, minHeight: metrics.controlMinHeight)
        .help("Remove external ref")
        .accessibilityLabel("Remove external ref")
      }
    }
  }

  func externalDestination(for ref: TaskBoardExternalRef) -> TaskBoardExternalDestination? {
    guard let rawURL = ref.url, let url = URL(string: rawURL) else {
      return nil
    }
    return TaskBoardExternalDestination(label: externalLabel(for: ref), url: url)
  }

  func externalLabel(for ref: TaskBoardExternalRef) -> String {
    "\(ref.provider.title) \(ref.externalId)"
  }
}
