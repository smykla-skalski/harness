import Foundation
import SwiftData

public actor SupervisorPolicyConfigRepository {
  private let modelContainer: ModelContainer

  public init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
  }

  public func fetchRows() throws -> [PolicyConfigRowSnapshot] {
    let context = ModelContext(modelContainer)
    let descriptor = FetchDescriptor<PolicyConfigRow>(
      sortBy: [SortDescriptor(\.ruleID)]
    )
    return try context.fetch(descriptor).map(PolicyConfigRowSnapshot.init(row:))
  }

  public func save(_ snapshot: PolicyConfigRowSnapshot) throws {
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    let ruleID = snapshot.ruleID
    let descriptor = FetchDescriptor<PolicyConfigRow>(
      predicate: #Predicate { $0.ruleID == ruleID }
    )
    let row =
      try context.fetch(descriptor).first
      ?? {
        let newRow = PolicyConfigRow(
          ruleID: snapshot.ruleID,
          enabled: snapshot.enabled,
          defaultBehavior: snapshot.defaultBehaviorRaw,
          parametersJSON: snapshot.parametersJSON
        )
        context.insert(newRow)
        return newRow
      }()
    row.enabled = snapshot.enabled
    row.defaultBehaviorRaw = snapshot.defaultBehaviorRaw
    row.parametersJSON = snapshot.parametersJSON
    row.updatedAt = Date()
    try context.save()
  }

  public func delete(ruleID: String) throws {
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    let descriptor = FetchDescriptor<PolicyConfigRow>(
      predicate: #Predicate { $0.ruleID == ruleID }
    )
    for row in try context.fetch(descriptor) {
      context.delete(row)
    }
    try context.save()
  }

  public func fetchOverrides() throws -> [PolicyConfigOverride] {
    try fetchRows().map { row in
      PolicyConfigOverride(
        ruleID: row.ruleID,
        enabled: row.enabled,
        defaultBehavior: RuleDefaultBehavior(rawValue: row.defaultBehaviorRaw) ?? .cautious,
        parameters: Self.decodeParameters(from: row.parametersJSON)
      )
    }
  }

  public func waitForIdle() {}

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
