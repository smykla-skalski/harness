import Foundation

extension WebSocketTransport {
  func responseError(
    method: WebSocketRPCMethod?,
    error: WsErrorPayload
  ) -> any Error {
    guard let statusCode = error.statusCode else {
      return WebSocketTransportError.serverError(
        code: error.code,
        message: error.message
      )
    }

    if method == .sessionAdopt,
      let adoptError = HarnessMonitorAPIClient.classifyAdoptError(
        statusCode: statusCode,
        payload: error.data
      )
    {
      return adoptError
    }

    if let data = error.data,
      let encoded = try? encoder.encode(data)
    {
      return HarnessMonitorAPIClient.decodeError(
        statusCode: statusCode,
        data: encoded
      )
    }

    return HarnessMonitorAPIError.server(code: statusCode, message: error.message)
  }
}
