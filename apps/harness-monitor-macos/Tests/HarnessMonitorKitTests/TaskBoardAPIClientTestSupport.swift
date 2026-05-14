import Foundation
import Testing

@testable import HarnessMonitorKit

actor RPCProbe {
  struct Call: Sendable {
    let method: WebSocketRPCMethod
    let params: JSONValue?
  }

  private(set) var calls: [Call] = []

  func record(method: WebSocketRPCMethod, params: JSONValue?) {
    calls.append(Call(method: method, params: params))
  }
}

func taskBoardRPCResponse(for method: WebSocketRPCMethod) throws -> JSONValue {
  guard let response = taskBoardRPCResponses[method] else {
    Issue.record("Unexpected RPC method \(method.rawValue)")
    throw HarnessMonitorAPIError.server(code: 500, message: "unexpected method")
  }
  return response
}

private let taskBoardRPCResponses: [WebSocketRPCMethod: JSONValue] = [
  .taskBoardList: .object(["items": .array([.object(sampleTaskBoardItemJSON)])]),
  .taskBoardCreate: .object(sampleTaskBoardItemJSON),
  .taskBoardGet: .object(sampleTaskBoardItemJSON),
  .taskBoardUpdate: .object(sampleTaskBoardItemJSON),
  .taskBoardDelete: .object(sampleTaskBoardItemJSON),
  .taskBoardSync: .object(["total": .number(1), "providers": .array([])]),
  .taskBoardDispatch: .object(sampleTaskBoardDispatchSummaryJSON),
  .taskBoardEvaluate: .object(sampleTaskBoardEvaluationSummaryJSON),
  .taskBoardAudit: .object([
    "total": .number(1),
    "ready": .number(1),
    "blocked": .number(0),
    "deleted": .number(0),
    "by_status": .array([]),
  ]),
  .taskBoardOrchestratorStatus: .object(sampleTaskBoardOrchestratorStatusJSON),
  .taskBoardOrchestratorStart: .object(sampleTaskBoardOrchestratorStatusJSON),
  .taskBoardOrchestratorStop: .object(sampleTaskBoardOrchestratorStatusJSON),
  .taskBoardOrchestratorRunOnce: .object(sampleTaskBoardOrchestratorRunOnceJSON),
  .taskBoardOrchestratorSettingsGet: .object(sampleTaskBoardOrchestratorSettingsJSON),
  .taskBoardOrchestratorSettingsUpdate: .object(sampleTaskBoardOrchestratorSettingsJSON),
]

final class TaskBoardURLProtocol: URLProtocol, @unchecked Sendable {
  struct RecordedRequest {
    let path: String
    let query: String?
    let method: String
    let body: [String: Any]?
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var recordedRequests: [RecordedRequest] = []

  static var records: [RecordedRequest] {
    lock.withLock { recordedRequests }
  }

  static func reset() {
    lock.withLock { recordedRequests = [] }
  }

  override static func canInit(with request: URLRequest) -> Bool {
    true
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    Self.lock.withLock {
      Self.recordedRequests.append(
        RecordedRequest(
          path: url.path,
          query: url.query,
          method: request.httpMethod ?? "",
          body: Self.jsonBody(for: request)
        )
      )
    }
    let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )
    guard let response else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(
      self,
      didLoad: Data(Self.responseBody(for: url.path, method: request.httpMethod ?? "").utf8)
    )
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func responseBody(for path: String, method: String) -> String {
    if path == "/v1/task-board/items", method == "GET" {
      return #"{"items":[\#(sampleTaskBoardItemJSONString)]}"#
    }
    if path == "/v1/task-board/sync" {
      return #"{"total":1,"providers":[]}"#
    }
    if path == "/v1/task-board/dispatch" {
      return sampleTaskBoardDispatchSummaryJSONString
    }
    if path == "/v1/task-board/evaluate" {
      return sampleTaskBoardEvaluationSummaryText
    }
    if path == "/v1/task-board/audit" {
      return #"{"total":1,"ready":1,"blocked":0,"deleted":0,"by_status":[]}"#
    }
    if path == "/v1/task-board/orchestrator/status" {
      return sampleOrchestratorStatusText
    }
    if path == "/v1/task-board/orchestrator/start" {
      return sampleOrchestratorStatusText
    }
    if path == "/v1/task-board/orchestrator/stop" {
      return sampleOrchestratorStatusText
    }
    if path == "/v1/task-board/orchestrator/run-once" {
      return sampleOrchestratorRunOnceText
    }
    if path == "/v1/task-board/orchestrator/settings" {
      return sampleOrchestratorSettingsText
    }
    return sampleTaskBoardItemJSONString
  }

  private static func jsonBody(for request: URLRequest) -> [String: Any]? {
    guard
      let data = bodyData(for: request),
      !data.isEmpty,
      let object = try? JSONSerialization.jsonObject(with: data),
      let body = object as? [String: Any]
    else {
      return nil
    }
    return body
  }

  private static func bodyData(for request: URLRequest) -> Data? {
    if let body = request.httpBody {
      return body
    }
    guard let stream = request.httpBodyStream else {
      return nil
    }
    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}
