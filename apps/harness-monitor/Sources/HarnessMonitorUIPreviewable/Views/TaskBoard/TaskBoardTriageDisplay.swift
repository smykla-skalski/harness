import HarnessMonitorKit
import SwiftUI

extension TriageVerdict {
  var title: String {
    switch self {
    case .todo:
      "Todo"
    case .undecided:
      "Undecided"
    }
  }
}

extension TriageReasonCode {
  /// Distinguishes the two automatic reasons that both land on `.undecided`:
  /// a needs-info label asks a person for more detail, while no meaningful
  /// label at all means triage simply has nothing to go on. Collapsing both
  /// into one "Undecided" label would hide that difference from the reader.
  var title: String {
    switch self {
    case .needsInfoLabel:
      "Needs info"
    case .noMeaningfulLabels:
      "No meaningful label"
    case .meaningfulLabel:
      "Meaningful label"
    }
  }
}

extension TaskBoardTriageEffectiveSource {
  var title: String {
    switch self {
    case .override:
      "Manual override"
    case .automatic:
      "Automatic"
    }
  }
}

extension TriageCause {
  var title: String {
    switch self {
    case .initial:
      "Initial evaluation"
    case .fingerprintChanged:
      "Evidence changed"
    case .activeEvaluatorChanged:
      "Evaluator changed"
    }
  }
}
