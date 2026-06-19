import Foundation

struct FlatErrorEnvelope: Decodable {
  let error: String
  let feature: String?
  let endpoint: String?
  let hint: String?
}

extension HarnessMonitorAPIClient {
  static func decodeError(statusCode: Int, data: Data) -> HarnessMonitorAPIError {
    // ErrorEnvelope/FlatErrorEnvelope are all single-word keys, so the plain decoder
    // (no key strategy) decodes them identically - no convertFromSnakeCase needed.
    let decoder = PolicyWireCoding.decoder

    if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) {
      let rawMessage = String(data: data, encoding: .utf8) ?? envelope.error.message
      return .server(code: statusCode, message: rawMessage)
    }

    if let envelope = try? decoder.decode(FlatErrorEnvelope.self, from: data) {
      var parts = [envelope.error]
      if let feature = envelope.feature, !feature.isEmpty {
        parts.append(feature)
      }
      if let endpoint = envelope.endpoint, !endpoint.isEmpty {
        parts.append(endpoint)
      }
      if let hint = envelope.hint, !hint.isEmpty {
        parts.append(hint)
      }
      return .server(code: statusCode, message: parts.joined(separator: " - "))
    }

    let message = String(data: data, encoding: .utf8) ?? "Unknown daemon error"
    return .server(code: statusCode, message: message)
  }

  func decodeError(statusCode: Int, data: Data) -> HarnessMonitorAPIError {
    Self.decodeError(statusCode: statusCode, data: data)
  }

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
      var request = try makeRequest(path: DaemonTelemetrySupport.path)
      request.httpMethod = "POST"
      request.timeoutInterval = DaemonTelemetrySupport.requestTimeoutInterval
      request.httpBody = try encoder.encode(AnyEncodable(telemetryRequest))
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      let session = self.session
      Task.detached(priority: .utility) {
        await Self.sendDecodeFailureTelemetry(request: request, session: session)
      }
    } catch {
      HarnessMonitorLogger.api.warning(
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
        HarnessMonitorLogger.api.warning(
          """
          Decode-failure telemetry was rejected: \
          \(httpResponse.statusCode, privacy: .public)
          """
        )
      }
    } catch {
      HarnessMonitorLogger.api.warning(
        """
        Failed to record decode-failure telemetry: \
        \(error.localizedDescription, privacy: .public)
        """
      )
    }
  }
}
