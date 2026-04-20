import Foundation

extension HarnessMonitorAPIClient {
  public func startSession(request: SessionStartRequest) async throws -> SessionSummary {
    struct Response: Decodable { let state: SessionSummary }
    let response: Response = try await post("/v1/sessions", body: request)
    return response.state
  }
}
