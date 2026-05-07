import Testing

@testable import HarnessMonitorKit

struct HarnessMonitorRequestIDTests {
  @Test("Request IDs are lowercase")
  func requestIDsAreLowercase() {
    let requestID = HarnessMonitorRequestID.next()

    #expect(requestID == requestID.lowercased())
  }
}
