import Foundation

public struct AdoptSessionRequest: Encodable, Sendable, Equatable {
  public let bookmarkID: String?
  public let sessionRoot: String

  public init(bookmarkID: String?, sessionRoot: String) {
    self.bookmarkID = bookmarkID
    self.sessionRoot = sessionRoot
  }

  enum CodingKeys: String, CodingKey {
    case bookmarkID = "bookmark_id"
    case sessionRoot = "session_root"
  }
}

extension HarnessMonitorAPIClient {
  public func adoptSession(
    bookmarkID: String?,
    sessionRoot: URL
  ) async throws -> SessionSummary {
    let requestBody = AdoptSessionRequest(
      bookmarkID: bookmarkID,
      sessionRoot: sessionRoot.path
    )
    var urlRequest = try makeRequest(path: "/v1/sessions/adopt")
    urlRequest.httpMethod = "POST"
    urlRequest.httpBody = try encoder.encode(requestBody)
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await session.data(for: urlRequest)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw HarnessMonitorAPIError.invalidResponse
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      throw Self.classifyAdoptErrorFromData(
        statusCode: httpResponse.statusCode,
        data: data
      )
    }

    struct Response: Decodable { let state: SessionSummary }
    let decoded: Response = try decoder.decode(Response.self, from: data)
    return decoded.state
  }

  // Parses adopt-specific error shapes from raw response data before field stripping.
  // Falls back to the generic server error when the shape is unrecognised.
  static func classifyAdoptErrorFromData(
    statusCode: Int,
    data: Data
  ) -> HarnessMonitorAPIError {
    guard
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let tag = json["error"] as? String
    else {
      let message = String(data: data, encoding: .utf8) ?? "Unknown daemon error"
      return .server(code: statusCode, message: message)
    }

    switch (statusCode, tag) {
    case (409, "already-attached"):
      let sessionId = (json["session_id"] as? String) ?? ""
      return .adoptAlreadyAttached(sessionId: sessionId)
    case (422, "layout-violation"):
      let reason = (json["reason"] as? String) ?? ""
      return .adoptLayoutViolation(reason: reason)
    case (422, "origin-mismatch"):
      let expected = (json["expected"] as? String) ?? ""
      let found = (json["found"] as? String) ?? ""
      return .adoptOriginMismatch(expected: expected, found: found)
    case (422, "unsupported-schema-version"):
      let found = (json["found"] as? Int) ?? 0
      let supported = (json["supported"] as? Int) ?? 0
      return .adoptUnsupportedSchemaVersion(found: found, supported: supported)
    default:
      let message = String(data: data, encoding: .utf8) ?? "Unknown daemon error"
      return .server(code: statusCode, message: message)
    }
  }
}
