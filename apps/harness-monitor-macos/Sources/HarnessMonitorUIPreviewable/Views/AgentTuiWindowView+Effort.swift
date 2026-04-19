import Foundation
import HarnessMonitorKit

/// Constants and helpers that back the "Custom..." escape hatch and the
/// reasoning-effort picker in the agent startup form. Split from
/// `AgentTuiWindowView+Panes.swift` to keep each view file focused.
enum RuntimeCustomModel {
  /// Tag value used on the "Custom..." picker option. Chosen so it cannot
  /// collide with any real provider model id (those never start with a
  /// double underscore).
  static let tag = "__custom__"
}

extension AgentTuiWindowView {
  /// The union of effort levels the system exposes, in low → high order. Used
  /// by the "Custom..." option where there is no catalog entry to consult.
  static let allEffortLevels: [String] = ["off", "minimal", "low", "medium", "high"]

  /// Effort values to offer for a given model selection in a catalog. Returns
  /// an empty array when the model does not support effort; returns the union
  /// of all levels for the custom-model placeholder tag.
  static func effortValues(catalog: RuntimeModelCatalog, selectedModelId: String) -> [String] {
    if selectedModelId == RuntimeCustomModel.tag {
      return allEffortLevels
    }
    guard let model = catalog.models.first(where: { $0.id == selectedModelId }) else {
      return []
    }
    return model.effortValues
  }

  /// Produce the effective model identifier to send to the daemon, resolving
  /// the "Custom..." tag to the user's typed value. Returns `nil` when the
  /// user has not entered anything.
  static func effectiveModelId(
    pickerValue: String,
    customValue: String,
    catalogDefault: String
  ) -> (id: String?, allowCustom: Bool) {
    if pickerValue == RuntimeCustomModel.tag {
      let trimmed = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return (nil, true) }
      return (trimmed, true)
    }
    if pickerValue.isEmpty {
      return (catalogDefault.isEmpty ? nil : catalogDefault, false)
    }
    return (pickerValue, false)
  }

  /// Pick the default effort level for a set of offered values. Prefers
  /// `medium` when the runtime exposes it; otherwise falls back to the
  /// middle index, rounding down. Returns an empty string when no values
  /// are offered so callers can detect "no effort".
  static func defaultEffortLevel(from values: [String]) -> String {
    guard !values.isEmpty else { return "" }
    if let medium = values.first(where: { $0 == "medium" }) {
      return medium
    }
    let middleIndex = values.count / 2
    return values[middleIndex]
  }
}
