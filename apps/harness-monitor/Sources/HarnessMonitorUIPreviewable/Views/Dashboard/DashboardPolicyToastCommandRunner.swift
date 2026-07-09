import Foundation
import HarnessMonitorKit

@MainActor
struct DashboardPolicyToastCommandRunner {
  let toast: ToastSlice
  let policyID: String

  func showInitial(_ commands: [AutomationPolicyToastCommand]) {
    apply(commands, matching: .show)
  }

  func updateAfterResolution(_ commands: [AutomationPolicyToastCommand]) {
    apply(commands, matching: .update)
  }

  func finish(_ commands: [AutomationPolicyToastCommand]) {
    apply(commands, matching: .hide)
  }

  private func apply(
    _ commands: [AutomationPolicyToastCommand],
    matching kind: AutomationPolicyToastCommandKind
  ) {
    for command in commands where command.kind == kind {
      apply(command)
    }
  }

  private func apply(_ command: AutomationPolicyToastCommand) {
    switch command.kind {
    case .show:
      toast.presentActivity(
        key: toastKey(for: command),
        message: message(for: command, fallback: "Processing"),
        title: command.title,
        accessibilityIdentifier: accessibilityIdentifier(for: command),
        position: command.position
      )
    case .update:
      toast.updateActivity(
        key: toastKey(for: command),
        message: message(for: command, fallback: "Still working"),
        title: command.title,
        accessibilityIdentifier: accessibilityIdentifier(for: command),
        position: command.position
      )
    case .hide:
      toast.dismissActivity(key: toastKey(for: command))
    }
  }

  private func message(
    for command: AutomationPolicyToastCommand,
    fallback: String
  ) -> String {
    let message = command.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return message.isEmpty ? fallback : message
  }

  private func toastKey(for command: AutomationPolicyToastCommand) -> String {
    let key = command.key.trimmingCharacters(in: .whitespacesAndNewlines)
    return "policy.\(policyID).\(key.isEmpty ? "default" : key)"
  }

  private func accessibilityIdentifier(for command: AutomationPolicyToastCommand) -> String {
    "harness.dashboard.policy-toast.\(toastKey(for: command))"
  }
}
