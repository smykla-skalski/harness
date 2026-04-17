import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreLifecycleCoreTests {
  @Test("API client timeline summary scope adds the HTTP query parameter")
  func apiClientTimelineSummaryScopeAddsHTTPQueryParameter() async throws {
    SummaryTimelineURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SummaryTimelineURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: URL(string: "http://127.0.0.1:9999")!,
        token: "token"
      ),
      session: session
    )

    let entries = try await client.timeline(sessionID: "sess-http-summary", scope: .summary)

    #expect(entries.count == 1)
    #expect(
      SummaryTimelineURLProtocol.lastRequestURL?.path
        == "/v1/sessions/sess-http-summary/timeline"
    )
    #expect(SummaryTimelineURLProtocol.lastRequestURL?.query == "scope=summary")
    #expect(
      SummaryTimelineURLProtocol.lastRequestHeaders?["X-Request-Id"]?.isEmpty == false
    )
    #expect(
      SummaryTimelineURLProtocol.lastRequestHeaders?["traceparent"]?.isEmpty == false
    )
  }

  @Test("API client timeline window adds viewport query parameters")
  func apiClientTimelineWindowAddsViewportQueryParameters() async throws {
    TimelineWindowURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TimelineWindowURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: URL(string: "http://127.0.0.1:9999")!,
        token: "token"
      ),
      session: session
    )

    let response = try await client.timelineWindow(
      sessionID: "sess-http-window",
      request: .latest(limit: 10)
    )

    let requestURL = try #require(TimelineWindowURLProtocol.lastRequestURL)
    let queryItems =
      URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems ?? []

    #expect(response.totalCount == 42)
    #expect(requestURL.path == "/v1/sessions/sess-http-window/timeline")
    #expect(queryItems.contains(URLQueryItem(name: "scope", value: "summary")))
    #expect(queryItems.contains(URLQueryItem(name: "limit", value: "10")))
  }
}

private final class SummaryTimelineURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requestURL: URL?
  nonisolated(unsafe) private static var requestHeaders: [String: String]?

  static var lastRequestURL: URL? {
    lock.withLock { requestURL }
  }

  static var lastRequestHeaders: [String: String]? {
    lock.withLock { requestHeaders }
  }

  static func reset() {
    lock.withLock {
      requestURL = nil
      requestHeaders = nil
    }
  }

  override static func canInit(with request: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let requestURL = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    Self.lock.withLock {
      Self.requestURL = requestURL
      Self.requestHeaders = request.allHTTPHeaderFields
    }

    guard
      let response = HTTPURLResponse(
        url: requestURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let responseBody =
      """
      [
        {
          "entry_id": "entry-1",
          "recorded_at": "2026-04-14T03:00:00Z",
          "kind": "tool_result",
          "session_id": "sess-http-summary",
          "agent_id": null,
          "task_id": null,
          "summary": "Summary entry",
          "payload": {}
        }
      ]
      """
    let data = Data(responseBody.utf8)
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class TimelineWindowURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requestURL: URL?

  static var lastRequestURL: URL? {
    lock.withLock { requestURL }
  }

  static func reset() {
    lock.withLock {
      requestURL = nil
    }
  }

  override static func canInit(with request: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let requestURL = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    Self.lock.withLock {
      Self.requestURL = requestURL
    }

    guard
      let response = HTTPURLResponse(
        url: requestURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let responseBody =
      """
      {
        "revision": 7,
        "total_count": 42,
        "window_start": 0,
        "window_end": 10,
        "has_older": true,
        "has_newer": false,
        "oldest_cursor": {
          "recorded_at": "2026-04-14T03:09:00Z",
          "entry_id": "entry-10"
        },
        "newest_cursor": {
          "recorded_at": "2026-04-14T03:00:00Z",
          "entry_id": "entry-1"
        },
        "entries": [],
        "unchanged": false
      }
      """
    let data = Data(responseBody.utf8)
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
