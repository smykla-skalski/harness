import HarnessMonitorKit
import SwiftUI

struct AcpPermissionModal: View {
  let batch: AcpPermissionBatch
  let isResolving: Bool
  let resolve: (AcpPermissionDecision) -> Void

  @State private var selectedRequestIDs: Set<String>
  @FocusState private var denyFocused: Bool

  init(
    batch: AcpPermissionBatch,
    isResolving: Bool,
    resolve: @escaping (AcpPermissionDecision) -> Void
  ) {
    self.batch = batch
    self.isResolving = isResolving
    self.resolve = resolve
    _selectedRequestIDs = State(initialValue: Set(batch.requests.map(\.requestId)))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text(title)
        .scaledFont(.title3.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Text(summary)
        .scaledFont(.body)
        .accessibilityLabel(summary)

      ScrollView {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          ForEach(batch.requests, id: \.requestId) { request in
            Toggle(
              isOn: Binding {
                selectedRequestIDs.contains(request.requestId)
              } set: { isSelected in
                updateSelection(request.requestId, isSelected: isSelected)
              }
            ) {
              VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
                Text(permissionTitle(for: request))
                  .scaledFont(.body.weight(.medium))
                Text(permissionDetail(for: request))
                  .scaledFont(.caption)
                  .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                  .lineLimit(3)
              }
            }
            .toggleStyle(.checkbox)
            .disabled(isResolving)
            .accessibilityIdentifier("harness.acp-permission.item.\(request.requestId)")
          }
        }
      }
      .frame(maxHeight: 220)

      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Button("Deny All") {
          resolve(.denyAll)
        }
        .keyboardShortcut(.cancelAction)
        .focused($denyFocused)
        Spacer()
        Button("Approve Selected") {
          resolve(.approveSome(Array(selectedRequestIDs).sorted()))
        }
        .disabled(selectedRequestIDs.isEmpty || isResolving)
        Button("Approve All") {
          resolve(.approveAll)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isResolving)
      }
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .frame(width: 520)
    .onAppear {
      denyFocused = true
      AccessibilityNotification.Announcement(summary).post()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("harness.acp-permission.modal")
  }

  private var title: String {
    batch.requests.count == 1 ? "Agent permission required" : "Agent permissions required"
  }

  private var summary: String {
    let count = batch.requests.count
    let suffix = count == 1 ? "action" : "actions"
    return "\(batch.acpId) wants approval for \(count) \(suffix)."
  }

  private func updateSelection(_ requestID: String, isSelected: Bool) {
    if isSelected {
      selectedRequestIDs.insert(requestID)
    } else {
      selectedRequestIDs.remove(requestID)
    }
  }

  private func permissionTitle(for request: AcpPermissionItem) -> String {
    valueLabel(request.toolCall, key: "kind")
      ?? valueLabel(request.toolCall, key: "name")
      ?? valueLabel(request.toolCall, key: "tool")
      ?? "Tool call"
  }

  private func permissionDetail(for request: AcpPermissionItem) -> String {
    valueLabel(request.toolCall, key: "path")
      ?? valueLabel(request.toolCall, key: "command")
      ?? compactJSON(request.toolCall)
  }

  private func valueLabel(_ value: JSONValue, key: String) -> String? {
    guard case .object(let object) = value, case .string(let string)? = object[key],
      !string.isEmpty
    else {
      return nil
    }
    return string
  }

  private func compactJSON(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value),
      let text = String(data: data, encoding: .utf8)
    else {
      return "Permission request"
    }
    return text
  }
}
