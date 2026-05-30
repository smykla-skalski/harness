import Foundation

extension PolicyCanvasAutomationPolicyCompiler {
  static func sourceAppFilter(from text: String) -> AutomationSourceAppFilter {
    let identifiers = bundleIdentifiers(from: text)
    guard !identifiers.isEmpty else {
      return AutomationSourceAppFilter()
    }
    if containsAny(text, ["allow only", "allowed apps", "allowlist", "source apps only"]) {
      return AutomationSourceAppFilter(
        mode: .allowedOnly,
        allowedBundleIdentifiers: identifiers
      )
    }
    return AutomationSourceAppFilter(deniedBundleIdentifiers: identifiers)
  }

  static func bundleIdentifiers(from text: String) -> [String] {
    text
      .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
      .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
      .filter { $0.hasPrefix("com.") && $0.contains(".") }
  }

  static func nodeText(_ node: PolicyCanvasNode) -> String {
    var text = String()
    text.reserveCapacity(96)
    appendNodeText(node, to: &text)
    return text
  }

  static func appendNodeText(_ node: PolicyCanvasNode, to text: inout String) {
    appendGraphToken(node.id, to: &text)
    appendGraphToken(node.title, to: &text)
    appendGraphToken(node.subtitle, to: &text)
    appendGraphToken(node.kind.title, to: &text)
    if let policyKind = node.policyKind {
      appendGraphToken(policyKind.kind, to: &text)
      if let workflow = policyKind.workflow {
        appendGraphToken(workflow, to: &text)
      }
      if let ruleID = policyKind.ruleId {
        appendGraphToken(ruleID, to: &text)
      }
      if let reasonCode = policyKind.reasonCode {
        appendGraphToken(reasonCode, to: &text)
      }
      for reasonCode in policyKind.reasonCodes {
        appendGraphToken(reasonCode, to: &text)
      }
    }
  }

  static func appendGraphToken(_ token: String, to text: inout String) {
    guard !token.isEmpty else { return }
    if !text.isEmpty {
      text.append(" ")
    }
    text.append(token)
  }

  static func normalizedText(_ text: String) -> String {
    text
      .lowercased()
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "+", with: " ")
  }

  static func containsAny(_ text: String, _ needles: [String]) -> Bool {
    needles.contains { text.contains($0) }
  }

  static func containsWord(_ text: String, _ words: [String]) -> Bool {
    let paddedText = " \(text) "
    return words.contains { word in
      paddedText.contains(" \(word) ")
    }
  }
}
