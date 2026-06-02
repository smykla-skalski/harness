import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

/// Guards that every reason-code string the inspector can commit is a valid
/// Rust `PolicyReasonCode` variant. A drift here breaks save/simulate on the
/// daemon, which rejects unknown reason codes.
@Suite("Policy canvas reason-code validity")
@MainActor
struct PolicyCanvasReasonCodeValidityTests {
  private func reasonCodes(
    in kind: TaskBoardPolicyPipelineNodeKind
  ) -> [String] {
    var codes: [String] = []
    if let reasonCode = kind.reasonCode {
      codes.append(reasonCode)
    }
    codes.append(contentsOf: kind.reasonCodes)
    if let highRisk = kind.highRiskReasonCode {
      codes.append(highRisk)
    }
    if let missing = kind.missingReasonCode {
      codes.append(missing)
    }
    for check in kind.checks {
      codes.append(check.failReasonCode)
      codes.append(check.missingReasonCode)
    }
    return codes
  }

  @Test("node-template reason codes are valid Rust variants")
  func nodeTemplateReasonCodesAreValid() {
    var collected: [String] = []
    for kind in PolicyCanvasNodeKind.allCases {
      collected.append(contentsOf: reasonCodes(in: kind.defaultPolicyKind))
    }
    let unique = Set(collected)
    let invalid = unique.subtracting(PolicyCanvasReasonCode.allValid)
    #expect(unique.isSubset(of: PolicyCanvasReasonCode.allValid), "drift: \(invalid)")
  }

  @Test("risk and evidence commit paths write valid reason codes")
  func commitPathReasonCodesAreValid() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("risk-score"))

    viewModel.commitSelectedRiskThreshold(60)
    let riskKind = viewModel.node("risk-score")?.policyKind ?? .init(kind: "")
    let riskCodes = reasonCodes(in: riskKind)
    let riskInvalid = Set(riskCodes).subtracting(PolicyCanvasReasonCode.allValid)
    #expect(riskInvalid.isEmpty, "risk drift: \(riskInvalid)")

    viewModel.commitSelectedEvidenceField(.checksGreen)
    let evidenceKind = viewModel.node("risk-score")?.policyKind ?? .init(kind: "")
    let evidenceCodes = reasonCodes(in: evidenceKind)
    let evidenceInvalid = Set(evidenceCodes).subtracting(PolicyCanvasReasonCode.allValid)
    #expect(evidenceInvalid.isEmpty, "evidence drift: \(evidenceInvalid)")
  }
}
