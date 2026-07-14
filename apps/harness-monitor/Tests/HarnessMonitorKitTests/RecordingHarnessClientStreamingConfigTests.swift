import Testing

@testable import HarnessMonitorKit

@Suite("Recording client stream configuration")
struct RecordingHarnessClientStreamingConfigTests {
  @Test("Zero global stream failures does not inject an error")
  func zeroGlobalStreamFailuresDoesNotInjectError() async throws {
    let client = RecordingHarnessClient()
    client.configureGlobalStream(
      events: [.ready(recordedAt: "2026-07-14T14:00:00Z")],
      error: WebSocketTransportError.connectionClosed,
      failureCount: 0
    )

    var iterator = client.globalStream().makeAsyncIterator()

    #expect(try await iterator.next() != nil)
    #expect(try await iterator.next() == nil)
  }
}
