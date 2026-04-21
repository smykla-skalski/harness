import HarnessMonitorKit
import SwiftUI

@MainActor
struct AttachSessionSheetView: View {
  let store: HarnessMonitorStore
  let bookmarkID: String
  let preview: SessionDiscoveryProbe.Preview?
  let failure: SessionDiscoveryProbe.Failure?

  @State private var isAttaching = false

  init(
    store: HarnessMonitorStore,
    bookmarkID: String,
    preview: SessionDiscoveryProbe.Preview?,
    failure: SessionDiscoveryProbe.Failure? = nil
  ) {
    self.store = store
    self.bookmarkID = bookmarkID
    self.preview = preview
    self.failure = failure
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
      Divider()
      footer
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("attachSessionSheet")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Attach External Session")
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
      Text("Inspect and confirm before attaching to the daemon.")
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var content: some View {
    if let preview {
      previewBody(preview)
    } else if let failure {
      failureBody(failure)
    } else {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func previewBody(_ preview: SessionDiscoveryProbe.Preview) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      row(label: "Project", value: preview.projectName.isEmpty ? "(unknown)" : preview.projectName)
      row(label: "Session ID", value: preview.sessionId)
      row(label: "Title", value: preview.title.isEmpty ? "(untitled)" : preview.title)
      row(label: "Created", value: preview.createdAt.formatted(date: .abbreviated, time: .shortened))
      row(label: "Workspace", value: preview.sessionRoot.appendingPathComponent("workspace").path)
      row(label: "Memory", value: preview.sessionRoot.appendingPathComponent("memory").path)
      if !preview.originReachable {
        Label(
          "Origin is not reachable. Attach succeeds but will be read-only until re-authorized.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.yellow)
      }
    }
    .padding(HarnessMonitorTheme.spacingLG)
  }

  private func failureBody(_ failure: SessionDiscoveryProbe.Failure) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Label(failureTitle(failure), systemImage: "xmark.octagon.fill")
        .foregroundStyle(.red)
      Text(failureMessage(failure))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .padding(HarnessMonitorTheme.spacingLG)
  }

  private var footer: some View {
    HStack {
      Spacer()
      Button("Cancel") { store.dismissSheet() }
        .keyboardShortcut(.cancelAction)
      Button("Attach") {
        guard let preview else { return }
        isAttaching = true
        Task {
          await store.adoptExternalSession(bookmarkID: bookmarkID, preview: preview)
          isAttaching = false
        }
      }
      .keyboardShortcut(.defaultAction)
      .disabled(preview == nil || isAttaching)
    }
    .padding(HarnessMonitorTheme.spacingLG)
  }

  private func row(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .frame(width: 120, alignment: .leading)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(value)
        .lineLimit(2)
        .textSelection(.enabled)
    }
  }

  func failureTitle(_ failure: SessionDiscoveryProbe.Failure) -> String {
    switch failure {
    case .notAHarnessSession: "Not a harness session"
    case .unsupportedSchemaVersion: "Unsupported schema version"
    case .belongsToAnotherProject: "Belongs to another project"
    case .alreadyAttached: "Already attached"
    }
  }

  func failureMessage(_ failure: SessionDiscoveryProbe.Failure) -> String {
    switch failure {
    case .notAHarnessSession(let reason): reason
    case .unsupportedSchemaVersion(let found, let supported):
      "Schema version \(found) is not supported. This Monitor expects v\(supported)."
    case .belongsToAnotherProject(let expected, let found):
      "Expected origin \(expected), found \(found)."
    case .alreadyAttached(let sid):
      "Session \(sid) is already attached."
    }
  }
}
