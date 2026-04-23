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

  @ObservationIgnored private var overridesByRuleID: [String: RuleOverrideState] = [:]
  @ObservationIgnored private var parameterValuesByKey: [String: String] = [:]

  public init(rules: [any PolicyRule] = HarnessMonitorSupervisorRuleCatalog.makeRules()) {
    self.rules = rules.map(PreferencesSupervisorRuleDescriptor.init(rule:))
    let firstRule = self.rules.first
    selectedRuleID = firstRule?.id
    enabled = true
    defaultBehavior = firstRule?.defaultBehavior ?? .cautious
    if let firstRule {
      parameterValuesByKey = Self.defaultParameters(for: firstRule)
    }
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
    loadSelectedRule()
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

  private func loadSelectedRule() {
    guard let selectedRule else {
      enabled = true
      defaultBehavior = .cautious
      parameterValuesByKey = [:]
      return
    }

    if let override = overridesByRuleID[selectedRule.id] {
      enabled = override.enabled
      defaultBehavior = override.defaultBehavior
      parameterValuesByKey =
        Self.defaultParameters(for: selectedRule).merging(override.parameters) { _, newValue in
          newValue
        }
      return
    }

    applyBuiltInDefaults(for: selectedRule)
  }

  private func applyBuiltInDefaults(for rule: PreferencesSupervisorRuleDescriptor) {
    enabled = true
    defaultBehavior = rule.defaultBehavior
    parameterValuesByKey = Self.defaultParameters(for: rule)
  }

  private static func defaultParameters(
    for rule: PreferencesSupervisorRuleDescriptor
  ) -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: rule.parameters.fields.map { ($0.key, $0.default) }
    )
  }

  private static func decodeParameters(from json: String) -> [String: String] {
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
}

private struct RuleOverrideState {
  let enabled: Bool
  let defaultBehavior: RuleDefaultBehavior
  let parameters: [String: String]
}

public enum PreferencesSupervisorRulesViewModelError: Error {
  case noRuleSelected
  case invalidParametersEncoding
}
