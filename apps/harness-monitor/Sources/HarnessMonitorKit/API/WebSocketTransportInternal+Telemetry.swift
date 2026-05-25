import Foundation

extension WebSocketTransport {
  func enqueueDecodeFailureTelemetry(
    source: String,
    message: String,
    sample: String?
  ) {
    let telemetryRequest = DaemonTelemetryRequest(
      kind: .decodeFailure,
      source: source,
      message: message,
      sample: sample
    )
    do {
      let url = URL(
        string: DaemonTelemetrySupport.path,
        relativeTo: connection.endpoint
      )
      guard let url else {
        throw HarnessMonitorAPIError.invalidEndpoint(connection.endpoint.absoluteString)
      }
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.timeoutInterval = DaemonTelemetrySupport.requestTimeoutInterval
      request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.httpBody = try encoder.encode(AnyEncodable(telemetryRequest))
      let session = self.session
      Task.detached(priority: .utility) {
        await Self.sendDecodeFailureTelemetry(request: request, session: session)
      }
    } catch {
      HarnessMonitorLogger.websocket.warning(
        """
        Failed to record decode-failure telemetry: \
        \(error.localizedDescription, privacy: .public)
        """
      )
    }
  }

  private static func sendDecodeFailureTelemetry(
    request: URLRequest,
    session: URLSession
  ) async {
    do {
      let (_, response) = try await session.data(for: request)
      if let httpResponse = response as? HTTPURLResponse,
        !(200..<300).contains(httpResponse.statusCode)
      {
        HarnessMonitorLogger.websocket.warning(
          """
          Decode-failure telemetry was rejected: \
          \(httpResponse.statusCode, privacy: .public)
          """
        )
      }
    } catch {
      HarnessMonitorLogger.websocket.warning(
        """
        Failed to record decode-failure telemetry: \
        \(error.localizedDescription, privacy: .public)
        """
      )
    }
  }

  nonisolated func encodedTelemetrySample(from payload: JSONValue) -> String? {
    guard let data = try? Self.reencodeEncoder.encode(payload) else {
      return nil
    }
    return DaemonTelemetrySupport.truncatedSample(data)
  }
}
