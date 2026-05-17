import Foundation

extension SettingsSupervisorRulesViewModel {
  func applyPreparedRows(_ output: SettingsSupervisorRulesPreparedRows) {
    overridesByRuleID = output.overridesByRuleID
    editorStates = output.editorStates
  }

  nonisolated static func prepareRows(
    _ rows: [PolicyConfigRowSnapshot],
    rules: [SettingsSupervisorRuleDescriptor]
  ) -> SettingsSupervisorRulesPreparedRows {
    let overridesByRuleID = Dictionary(
      uniqueKeysWithValues: rows.map {
        (
          $0.ruleID,
          RuleOverrideState(
            enabled: $0.enabled,
            defaultBehavior: RuleDefaultBehavior(rawValue: $0.defaultBehaviorRaw) ?? .cautious,
            parameters: decodeParameters(from: $0.parametersJSON)
          )
        )
      }
    )
    let editorStates = Dictionary(
      uniqueKeysWithValues: rules.map { rule in
        if let override = overridesByRuleID[rule.id] {
          return (
            rule.id,
            RuleEditorState(
              enabled: override.enabled,
              defaultBehavior: override.defaultBehavior,
              parameterValues: defaultParameters(for: rule)
                .merging(override.parameters) { _, overrideValue in overrideValue }
            )
          )
        }
        return (rule.id, builtInEditorState(for: rule))
      }
    )
    return SettingsSupervisorRulesPreparedRows(
      overridesByRuleID: overridesByRuleID,
      editorStates: editorStates
    )
  }

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

  func applyBuiltInDefaults(for rule: SettingsSupervisorRuleDescriptor) {
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

  nonisolated static func builtInEditorState(
    for rule: SettingsSupervisorRuleDescriptor
  ) -> RuleEditorState {
    RuleEditorState(
      enabled: true,
      defaultBehavior: rule.defaultBehavior,
      parameterValues: defaultParameters(for: rule)
    )
  }

  nonisolated static func defaultParameters(
    for rule: SettingsSupervisorRuleDescriptor
  ) -> [String: String] {
    Dictionary(uniqueKeysWithValues: rule.parameters.fields.map { ($0.key, $0.default) })
  }

  nonisolated static func decodeParameters(from json: String) -> [String: String] {
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

  struct RuleOverrideState: Sendable {
    let enabled: Bool
    let defaultBehavior: RuleDefaultBehavior
    let parameters: [String: String]
  }

  struct RuleEditorState: Equatable, Sendable {
    var enabled: Bool
    var defaultBehavior: RuleDefaultBehavior
    var parameterValues: [String: String]
  }
}

struct SettingsSupervisorRulesPreparedRows: Sendable {
  let overridesByRuleID: [String: SettingsSupervisorRulesViewModel.RuleOverrideState]
  let editorStates: [String: SettingsSupervisorRulesViewModel.RuleEditorState]
}

actor SettingsSupervisorRulesWorker {
  func prepareRows(
    _ rows: [PolicyConfigRowSnapshot],
    rules: [SettingsSupervisorRuleDescriptor]
  ) -> SettingsSupervisorRulesPreparedRows {
    SettingsSupervisorRulesViewModel.prepareRows(rows, rules: rules)
  }

  func waitForIdle() async {}
}

public enum SettingsSupervisorRulesViewModelError: Error {
  case noRuleSelected
  case invalidParametersEncoding
}
