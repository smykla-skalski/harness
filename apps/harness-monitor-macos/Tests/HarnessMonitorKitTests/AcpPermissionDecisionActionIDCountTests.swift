import HarnessMonitorKit
import Testing

@Suite struct AcpPermissionDecisionActionIDCountTests {
  @Test func approveSingleRequestPicksApprove() {
    #expect(
      AcpPermissionDecisionActionID.approveActionID(forRequestCount: 1)
        == AcpPermissionDecisionActionID.approve
    )
  }

  @Test func approveEmptyBatchStillPicksApprove() {
    #expect(
      AcpPermissionDecisionActionID.approveActionID(forRequestCount: 0)
        == AcpPermissionDecisionActionID.approve
    )
  }

  @Test func approveMultiRequestPicksApproveAll() {
    #expect(
      AcpPermissionDecisionActionID.approveActionID(forRequestCount: 2)
        == AcpPermissionDecisionActionID.approveAll
    )
    #expect(
      AcpPermissionDecisionActionID.approveActionID(forRequestCount: 8)
        == AcpPermissionDecisionActionID.approveAll
    )
  }

  @Test func denySingleRequestPicksDeny() {
    #expect(
      AcpPermissionDecisionActionID.denyActionID(forRequestCount: 1)
        == AcpPermissionDecisionActionID.deny
    )
  }

  @Test func denyEmptyBatchStillPicksDeny() {
    #expect(
      AcpPermissionDecisionActionID.denyActionID(forRequestCount: 0)
        == AcpPermissionDecisionActionID.deny
    )
  }

  @Test func denyMultiRequestPicksDenyAll() {
    #expect(
      AcpPermissionDecisionActionID.denyActionID(forRequestCount: 2)
        == AcpPermissionDecisionActionID.denyAll
    )
    #expect(
      AcpPermissionDecisionActionID.denyActionID(forRequestCount: 16)
        == AcpPermissionDecisionActionID.denyAll
    )
  }
}
