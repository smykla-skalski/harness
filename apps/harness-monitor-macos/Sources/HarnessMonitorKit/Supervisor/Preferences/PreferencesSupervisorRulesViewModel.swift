import Foundation
import Observation

public struct PreferencesSupervisorRuleDescriptor: Identifiable, Hashable {
  public let id: String
  public let name: String
  public let version: Int
  public let parameters: PolicyParameterSchema
  public let defaultBehavior: RuleDefaultBehavior

  public init(rule: any PolicyRule) {
    id = rule.id
    name = rule.name
    version = rule.version
    parameters = rule.parameters
    defaultBehavior = rule.defaultBehavior(for: "")
  }
}

@MainActor
@Observable
public final class PreferencesSupervisorRulesViewModel {
  public var selectedRuleID: String?
  public var enabled: Bool
  public var defaultBehavior: RuleDefaultBehavior

  public let rules: [PreferencesSupervisorRuleDescriptor]

  @ObservationIgnored var overridesByRuleID: [String: RuleOverrideState] = [:]
  @ObservationIgnored var parameterValuesByKey: [String: String] = [:]
  var editorStates: [String: RuleEditorState] = [:]

  public init(rules: [any PolicyRule] = HarnessMonitorSupervisorRuleCatalog.makeRules()) {
    self.rules = rules.map(PreferencesSupervisorRuleDescriptor.init(rule:))
    let firstRule = self.rules.first
    selectedRuleID = firstRule?.id
    enabled = true
    defaultBehavior = firstRule?.defaultBehavior ?? .cautious
    if let firstRule {
      parameterValuesByKey = Self.defaultParameters(for: firstRule)
    }
    editorStates = Dictionary(
      uniqueKeysWithValues: self.rules.map { rule in
        (rule.id, Self.builtInEditorState(for: rule))
      }
    )
  }

  public var selectedRule: PreferencesSupervisorRuleDescriptor? {
    guard let selectedRuleID else {
      return nil
    }
    return rules.first(where: { $0.id == selectedRuleID })
  }

  public func selectRule(id: String) {
    guard selectedRuleID != id else {
      return
    }
    selectedRuleID = id
    loadSelectedRule()
  }

  public func applyRows(_ rows: [PolicyConfigRow]) {
    overridesByRuleID = Dictionary(
      uniqueKeysWithValues: rows.map {
        (
          $0.ruleID,
          RuleOverrideState(
            enabled: $0.enabled,
            defaultBehavior: RuleDefaultBehavior(rawValue: $0.defaultBehaviorRaw) ?? .cautious,
            parameters: Self.decodeParameters(from: $0.parametersJSON)
          )
        )
      }
    )
    for rule in rules {
      if let override = overridesByRuleID[rule.id] {
        editorStates[rule.id] = RuleEditorState(
          enabled: override.enabled,
          defaultBehavior: override.defaultBehavior,
          parameterValues: Self.defaultParameters(for: rule)
            .merging(override.parameters) { _, overrideValue in overrideValue }
        )
      } else {
        editorStates[rule.id] = Self.builtInEditorState(for: rule)
      }
    }
    loadSelectedRule()
  }

  public func isRuleEnabled(_ ruleID: String) -> Bool {
    editorStates[ruleID]?.enabled ?? true
  }

  public func setRuleEnabled(_ value: Bool, ruleID: String) {
    guard var state = editorStates[ruleID] else { return }
    state.enabled = value
    editorStates[ruleID] = state
    syncSelectedRuleState(ruleID: ruleID)
  }

  public func ruleDefaultBehavior(ruleID: String) -> RuleDefaultBehavior {
    editorStates[ruleID]?.defaultBehavior
      ?? rules.first(where: { $0.id == ruleID })?.defaultBehavior
      ?? .cautious
  }

  public func setRuleDefaultBehavior(_ value: RuleDefaultBehavior, ruleID: String) {
    guard var state = editorStates[ruleID] else { return }
    state.defaultBehavior = value
    editorStates[ruleID] = state
    syncSelectedRuleState(ruleID: ruleID)
  }

  public func ruleParameterValue(for key: String, ruleID: String) -> String {
    if let value = editorStates[ruleID]?.parameterValues[key] {
      return value
    }
    return rules.first(where: { $0.id == ruleID })?
      .parameters.fields.first(where: { $0.key == key })?.default ?? ""
  }

  public func setRuleParameterValue(_ value: String, for key: String, ruleID: String) {
    guard var state = editorStates[ruleID] else { return }
    state.parameterValues[key] = value
    editorStates[ruleID] = state
    syncSelectedRuleState(ruleID: ruleID)
  }

  public func resetRule(ruleID: String) {
    guard let rule = rules.first(where: { $0.id == ruleID }) else { return }
    editorStates[ruleID] = Self.builtInEditorState(for: rule)
    syncSelectedRuleState(ruleID: ruleID)
  }

  public func isRuleAtBuiltInDefaults(_ ruleID: String) -> Bool {
    guard
      let rule = rules.first(where: { $0.id == ruleID }),
      let state = editorStates[ruleID]
    else {
      return true
    }
    return state == Self.builtInEditorState(for: rule)
  }

  public func makePolicyConfigRow(forRuleID ruleID: String) throws -> PolicyConfigRow {
    guard
      let rule = rules.first(where: { $0.id == ruleID }),
      let state = editorStates[ruleID]
    else {
      throw PreferencesSupervisorRulesViewModelError.noRuleSelected
    }
    let parameters = Dictionary(
      uniqueKeysWithValues: rule.parameters.fields.map { field in
        (field.key, state.parameterValues[field.key] ?? field.default)
      }
    )
    let data = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
    guard let json = String(bytes: data, encoding: .utf8) else {
      throw PreferencesSupervisorRulesViewModelError.invalidParametersEncoding
    }
    return PolicyConfigRow(
      ruleID: rule.id,
      enabled: state.enabled,
      defaultBehavior: state.defaultBehavior.rawValue,
      parametersJSON: json
    )
  }

  public func parameterValue(for key: String) -> String {
    parameterValuesByKey[key]
      ?? selectedRule?.parameters.fields.first(where: { $0.key == key })?.default
      ?? ""
  }

  public func setParameterValue(_ value: String, for key: String) {
    parameterValuesByKey[key] = value
  }

  public func resetSelectedRule() {
    guard let selectedRule else {
      return
    }
    applyBuiltInDefaults(for: selectedRule)
  }

  public func makePolicyConfigRow() throws -> PolicyConfigRow {
    guard let selectedRule else {
      throw PreferencesSupervisorRulesViewModelError.noRuleSelected
    }
    let parameters = Dictionary(
      uniqueKeysWithValues: selectedRule.parameters.fields.map { field in
        (field.key, parameterValue(for: field.key))
      }
    )
    let data = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
    guard let json = String(bytes: data, encoding: .utf8) else {
      throw PreferencesSupervisorRulesViewModelError.invalidParametersEncoding
    }
    return PolicyConfigRow(
      ruleID: selectedRule.id,
      enabled: enabled,
      defaultBehavior: defaultBehavior.rawValue,
      parametersJSON: json
    )
  }
}
