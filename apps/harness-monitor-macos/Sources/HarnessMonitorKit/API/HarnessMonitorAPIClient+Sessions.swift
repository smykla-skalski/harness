import Foundation

extension HarnessMonitorAPIClient {
  public func startSession(request: SessionStartRequest) async throws -> SessionStartResult {
    let response: SessionStartMutationResponse = try await post("/v1/sessions", body: request)
    return response.result
  }
}
