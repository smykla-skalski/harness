import Foundation

extension PreferencesSupervisorRulesViewModel {
  func loadSelectedRule() {
    guard let selectedRule else {
      enabled = true
      defaultBehavior = .cautious
      parameterValuesByKey = [:]
      return
    }

    if let state = editorStates[selectedRule.id] {
      enabled = state.enabled
      defaultBehavior = state.defaultBehavior
      parameterValuesByKey = state.parameterValues
      return
    }

    applyBuiltInDefaults(for: selectedRule)
  }

  func applyBuiltInDefaults(for rule: PreferencesSupervisorRuleDescriptor) {
    enabled = true
    defaultBehavior = rule.defaultBehavior
    parameterValuesByKey = Self.defaultParameters(for: rule)
    editorStates[rule.id] = RuleEditorState(
      enabled: true,
      defaultBehavior: rule.defaultBehavior,
      parameterValues: parameterValuesByKey
    )
  }

  func syncSelectedRuleState(ruleID: String) {
    guard selectedRuleID == ruleID, let state = editorStates[ruleID] else { return }
    enabled = state.enabled
    defaultBehavior = state.defaultBehavior
    parameterValuesByKey = state.parameterValues
  }

  static func builtInEditorState(
    for rule: PreferencesSupervisorRuleDescriptor
  ) -> RuleEditorState {
    RuleEditorState(
      enabled: true,
      defaultBehavior: rule.defaultBehavior,
      parameterValues: defaultParameters(for: rule)
    )
  }

  static func defaultParameters(
    for rule: PreferencesSupervisorRuleDescriptor
  ) -> [String: String] {
    Dictionary(uniqueKeysWithValues: rule.parameters.fields.map { ($0.key, $0.default) })
  }

  static func decodeParameters(from json: String) -> [String: String] {
    guard
      let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }

    var parameters: [String: String] = [:]
    for (key, value) in object {
      switch value {
      case let string as String:
        parameters[key] = string
      case let number as NSNumber:
        parameters[key] = number.stringValue
      default:
        continue
      }
    }
    return parameters
  }

  struct RuleOverrideState {
    let enabled: Bool
    let defaultBehavior: RuleDefaultBehavior
    let parameters: [String: String]
  }

  struct RuleEditorState: Equatable {
    var enabled: Bool
    var defaultBehavior: RuleDefaultBehavior
    var parameterValues: [String: String]
  }
}

public enum PreferencesSupervisorRulesViewModelError: Error {
  case noRuleSelected
  case invalidParametersEncoding
}
