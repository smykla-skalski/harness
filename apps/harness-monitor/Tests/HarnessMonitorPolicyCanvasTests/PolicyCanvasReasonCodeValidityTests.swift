import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

/// Guards that every reason code the inspector can commit is a valid Rust
/// `PolicyReasonCode` variant. With the typed enum this is now a near-tautology,
/// but it still pins the node-template defaults to the daemon's accepted set so
/// a future template edit cannot reintroduce an out-of-band code.
@Suite("Policy canvas reason-code validity")
@MainActor
struct PolicyCanvasReasonCodeValidityTests {
  private func reasonCodes(
    in kind: PolicyGraphNodeKind
  ) -> [String] {
    var codes: [PolicyReasonCode] = []
    switch kind {
    case .humanGate(let code), .consensusGate(let code), .dryRunGate(let code):
      codes.append(code)
    case .supervisorRule(_, let reasonCodes):
      codes.append(contentsOf: reasonCodes)
    case .finish(let node):
      codes.append(node.reasonCode)
    case .riskClassifier(_, _, let highRisk, let missing):
      codes.append(highRisk)
      codes.append(missing)
    case .evidenceCheck(let checks):
      for check in checks {
        codes.append(check.failReasonCode)
        codes.append(check.missingReasonCode)
      }
    default:
      break
    }
    return codes.map(\.rawValue)
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
    let riskKind = viewModel.node("risk-score")?.policyKind ?? .hub
    let riskCodes = reasonCodes(in: riskKind)
    let riskInvalid = Set(riskCodes).subtracting(PolicyCanvasReasonCode.allValid)
    #expect(riskInvalid.isEmpty, "risk drift: \(riskInvalid)")

    viewModel.commitSelectedEvidenceField(.checksGreen)
    let evidenceKind = viewModel.node("risk-score")?.policyKind ?? .hub
    let evidenceCodes = reasonCodes(in: evidenceKind)
    let evidenceInvalid = Set(evidenceCodes).subtracting(PolicyCanvasReasonCode.allValid)
    #expect(evidenceInvalid.isEmpty, "evidence drift: \(evidenceInvalid)")
  }
}
