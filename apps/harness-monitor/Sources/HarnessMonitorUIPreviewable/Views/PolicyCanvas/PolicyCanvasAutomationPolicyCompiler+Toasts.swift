import Foundation
import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasAutomationPolicyCompiler {
  static func activityToastAction(from node: PolicyCanvasNode) -> AutomationPolicyAction? {
    if let action = node.automationBinding?.selectedActions.first(where: \.isActivityToastAction) {
      return action
    }
    let text = normalizedText(nodeText(node))
    if containsAny(
      text,
      ["hide activity toast", "hide progress", "hide spinner", "dismiss toast"]
    ) {
      return .hideActivityToast
    }
    if containsAny(text, ["update activity toast", "update progress", "change toast"]) {
      return .updateActivityToast
    }
    if containsAny(text, ["activity toast", "progress toast", "show spinner", "show progress"]) {
      return .showActivityToast
    }
    return nil
  }

  static func activityToastCommand(from node: PolicyCanvasNode)
    -> AutomationPolicyToastCommand?
  {
    guard let action = activityToastAction(from: node) else {
      return nil
    }
    return AutomationPolicyToastCommand(
      key: activityToastKey(from: node),
      kind: action.toastCommandKind,
      title: activityToastTitle(from: node),
      message: activityToastMessage(from: node, action: action),
      position: activityToastPosition(from: node)
    )
  }

  private static func activityToastKey(from node: PolicyCanvasNode) -> String {
    let rawText = [node.title, node.subtitle, node.id].joined(separator: " ")
    for marker in ["toast key:", "toast id:", "key:", "id:"] {
      if let value = valueAfter(marker, in: rawText), !value.isEmpty {
        return slug(value)
      }
    }
    return "default"
  }

  private static func activityToastTitle(from node: PolicyCanvasNode) -> String? {
    let trimmed = node.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.lowercased().contains("toast") || trimmed.lowercased().contains("spinner") {
      return nil
    }
    return trimmed
  }

  private static func activityToastMessage(
    from node: PolicyCanvasNode,
    action: AutomationPolicyAction
  ) -> String? {
    guard action != .hideActivityToast else {
      return nil
    }
    if let message = valueAfter("message:", in: node.subtitle), !message.isEmpty {
      return message
    }
    if let message = valueAfter(":", in: node.title), !message.isEmpty {
      return message
    }
    let subtitle = node.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !subtitle.isEmpty {
      return subtitle
    }
    switch action {
    case .showActivityToast:
      return "Processing"
    case .updateActivityToast:
      return "Still working"
    default:
      return nil
    }
  }

  private static func activityToastPosition(from node: PolicyCanvasNode)
    -> ActionFeedback.Position?
  {
    let rawText = [node.title, node.subtitle, node.id].joined(separator: " ")
    for marker in ["toast position:", "position:"] {
      if let value = valueAfter(marker, in: rawText),
        let position = activityToastPosition(fromValue: value)
      {
        return position
      }
    }

    let text = normalizedText(rawText)
    if containsAny(text, ["bottom trailing", "bottom right", "position bottom"]) {
      return .bottomTrailing
    }
    if containsAny(text, ["top trailing", "top right", "position top"]) {
      return .topTrailing
    }
    return nil
  }

  private static func activityToastPosition(fromValue value: String)
    -> ActionFeedback.Position?
  {
    let normalized = normalizedText(value.trimmingCharacters(in: .whitespacesAndNewlines))
    if normalized.hasPrefix("bottom") || normalized.contains("bottom trailing")
      || normalized.contains("bottom right")
    {
      return .bottomTrailing
    }
    if normalized.hasPrefix("top") || normalized.contains("top trailing")
      || normalized.contains("top right")
    {
      return .topTrailing
    }
    return nil
  }

  private static func valueAfter(_ marker: String, in text: String) -> String? {
    guard let range = text.range(of: marker, options: [.caseInsensitive]) else {
      return nil
    }
    let remainder = text[range.upperBound...]
    return
      remainder
      .split(whereSeparator: { $0.isNewline })
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension AutomationPolicyAction {
  var isActivityToastAction: Bool {
    switch self {
    case .showActivityToast, .updateActivityToast, .hideActivityToast:
      true
    default:
      false
    }
  }

  var toastCommandKind: AutomationPolicyToastCommandKind {
    switch self {
    case .showActivityToast:
      .show
    case .updateActivityToast:
      .update
    case .hideActivityToast:
      .hide
    default:
      .update
    }
  }
}
