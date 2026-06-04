import Foundation
import HarnessMonitorPolicyCanvasAlgorithms

public enum PolicyCanvasLabToolbarDefaults {
  public static let sampleSelectionKey = "policyCanvasLabSampleSelection"
  public static let algorithmSelectionKey = "policyCanvasLabAlgorithmSelection"
  public static let defaultSampleSelectionRawValue = PolicyCanvasLabSamples.defaultSelectionID
  public static let defaultAlgorithmSelectionRawValue =
    PolicyCanvasAlgorithmSelection.referenceRouting.cacheIdentity

  public static func selection(
    in defaults: UserDefaults = .standard
  ) -> PolicyCanvasLabSelection? {
    selection(rawValue: defaults.string(forKey: sampleSelectionKey))
  }

  public static func algorithmSelection(
    in defaults: UserDefaults = .standard
  ) -> PolicyCanvasAlgorithmSelection {
    algorithmSelection(rawValue: defaults.string(forKey: algorithmSelectionKey))
      ?? .referenceRouting
  }

  public static func rawValue(for selection: PolicyCanvasLabSelection) -> String {
    switch selection {
    case .live:
      "live"
    case .sample(let id):
      id
    }
  }

  public static func rawValue(for selection: PolicyCanvasAlgorithmSelection) -> String {
    selection.cacheIdentity
  }

  public static func selection(rawValue: String?) -> PolicyCanvasLabSelection? {
    guard let rawValue, !rawValue.isEmpty else {
      return nil
    }
    if rawValue == "live" {
      return .live
    }
    guard PolicyCanvasLabSamples.sample(id: rawValue) != nil else {
      return nil
    }
    return .sample(rawValue)
  }

  public static func algorithmSelection(
    rawValue: String?
  ) -> PolicyCanvasAlgorithmSelection? {
    guard let rawValue, !rawValue.isEmpty else {
      return nil
    }

    let optionsByStage = Dictionary(
      uniqueKeysWithValues: PolicyCanvasAlgorithmPickerCatalog.stageDescriptors.map {
        ($0.stage, Set($0.options.map(\.id)))
      }
    )
    var selectedAlgorithmIDs: [PolicyCanvasAlgorithmStage: PolicyCanvasAlgorithmID] = [:]

    for component in rawValue.split(separator: "|", omittingEmptySubsequences: false) {
      let pair = component.split(
        separator: "=",
        maxSplits: 1,
        omittingEmptySubsequences: false
      )
      guard
        pair.count == 2,
        !pair[0].isEmpty,
        !pair[1].isEmpty,
        let stage = PolicyCanvasAlgorithmStage(rawValue: String(pair[0])),
        selectedAlgorithmIDs[stage] == nil
      else {
        return nil
      }

      let algorithmID = PolicyCanvasAlgorithmID(String(pair[1]))
      guard optionsByStage[stage]?.contains(algorithmID) == true else {
        return nil
      }
      selectedAlgorithmIDs[stage] = algorithmID
    }

    return PolicyCanvasAlgorithmSelection(selectedAlgorithmIDs: selectedAlgorithmIDs)
  }
}
