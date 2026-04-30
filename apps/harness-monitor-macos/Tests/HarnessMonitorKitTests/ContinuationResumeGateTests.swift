import Testing

@testable import HarnessMonitorKit

@Suite("Continuation resume guard")
struct ContinuationResumeGateTests {
  @Test("allows only first resume attempt")
  func allowsOnlyFirstResumeAttempt() {
    let gate = ContinuationResumeGate()

    #expect(gate.tryBeginResume())
    #expect(!gate.tryBeginResume())
    #expect(!gate.tryBeginResume())
  }
}
