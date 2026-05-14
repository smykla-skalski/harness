import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Task-board daemon API client", .serialized)
struct TaskBoardAPIClientTests {
  @Test("HTTP client uses task-board route contract")
  func httpClientUsesTaskBoardRoutes() async throws {
    TaskBoardURLProtocol.reset()
    let client = try makeClient()

    _ = try await client.taskBoardItems(status: .todo)
    _ = try await client.taskBoardItem(id: "board-1")
    _ = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "Board item",
        body: "Body",
        priority: .high,
        agentMode: .interactive,
        tags: ["automation"],
        projectId: "project-1",
        sessionId: "sess-1",
        workItemId: "task-1",
        id: "board-1"
      )
    )
    _ = try await client.updateTaskBoardItem(
      id: "board-1",
      request: TaskBoardUpdateItemRequest(
        status: .inProgress,
        clearSessionId: true,
        clearWorkItemId: true
      )
    )
    _ = try await client.deleteTaskBoardItem(id: "board-1")
    _ = try await client.syncTaskBoard(status: .todo)
    let dispatch = try await client.dispatchTaskBoard(
      status: .todo,
      dryRun: false,
      projectDir: "/tmp/harness"
    )
    _ = try await client.auditTaskBoard(status: .blocked)

    let records = TaskBoardURLProtocol.records
    #expect(
      records.map(\.method)
        == ["GET", "GET", "POST", "PUT", "DELETE", "POST", "POST", "GET"]
    )
    #expect(
      records.map(\.path)
        == [
          "/v1/task-board/items",
          "/v1/task-board/items/board-1",
          "/v1/task-board/items",
          "/v1/task-board/items/board-1",
          "/v1/task-board/items/board-1",
          "/v1/task-board/sync",
          "/v1/task-board/dispatch",
          "/v1/task-board/audit",
        ]
    )
    #expect(records[0].query == "status=todo")
    #expect(records[2].body?["body"] as? String == "Body")
    #expect(records[2].body?["agent_mode"] as? String == "interactive")
    #expect(records[2].body?["tags"] as? [String] == ["automation"])
    #expect(records[2].body?["project_id"] as? String == "project-1")
    #expect(records[2].body?["session_id"] as? String == "sess-1")
    #expect(records[2].body?["work_item_id"] as? String == "task-1")
    #expect(records[2].body?["id"] as? String == "board-1")
    #expect(records[3].body?["status"] as? String == "in_progress")
    #expect(records[3].body?["clear_session_id"] as? Bool == true)
    #expect(records[3].body?["clear_work_item_id"] as? Bool == true)
    #expect(records[5].body?["status"] as? String == "todo")
    #expect(records[6].body?["status"] as? String == "todo")
    #expect(records[6].body?["dry_run"] as? Bool == false)
    #expect(records[6].body?["project_dir"] as? String == "/tmp/harness")
    #expect(records[7].query == "status=blocked")
    #expect(dispatch.plans.first?.task.title == "Board item")
    #expect(dispatch.plans.first?.policy?.decision == "allow")
    #expect(dispatch.applied.first?.workItemId == "task-1")
  }

  @Test("WebSocket transport uses task-board RPC contract")
  func webSocketTransportUsesTaskBoardRPCContract() async throws {
    let probe = RPCProbe()
    let transport = WebSocketTransport(
      connection: HarnessMonitorConnection(
        endpoint: try #require(URL(string: "http://127.0.0.1:1")),
        token: "token"
      ),
      session: URLSession(configuration: .ephemeral),
      rpcSender: { method, params, _ in
        await probe.record(method: method, params: params)
        switch method {
        case .taskBoardList:
          return .object(["items": .array([.object(sampleTaskBoardItemJSON)])])
        case .taskBoardCreate, .taskBoardGet, .taskBoardUpdate, .taskBoardDelete:
          return .object(sampleTaskBoardItemJSON)
        case .taskBoardSync:
          return .object(["total": .number(1), "providers": .array([])])
        case .taskBoardDispatch:
          return .object(sampleTaskBoardDispatchSummaryJSON)
        case .taskBoardAudit:
          return .object([
            "total": .number(1),
            "ready": .number(1),
            "blocked": .number(0),
            "deleted": .number(0),
            "by_status": .array([]),
          ])
        default:
          Issue.record("Unexpected RPC method \(method.rawValue)")
          throw HarnessMonitorAPIError.server(code: 500, message: "unexpected method")
        }
      }
    )

    _ = try await transport.taskBoardItems(status: TaskBoardStatus.todo)
    _ = try await transport.taskBoardItem(id: "board-1")
    _ = try await transport.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(title: "Board item"))
    _ = try await transport.updateTaskBoardItem(
      id: "board-1",
      request: TaskBoardUpdateItemRequest(status: .done)
    )
    _ = try await transport.deleteTaskBoardItem(id: "board-1")
    _ = try await transport.syncTaskBoard(status: TaskBoardStatus.todo)
    let dispatch = try await transport.dispatchTaskBoard(
      status: TaskBoardStatus.todo,
      dryRun: false,
      projectDir: "/tmp/harness"
    )
    _ = try await transport.auditTaskBoard(status: TaskBoardStatus.blocked)

    let calls = await probe.calls
    #expect(
      calls.map(\.method)
        == [
          .taskBoardList,
          .taskBoardGet,
          .taskBoardCreate,
          .taskBoardUpdate,
          .taskBoardDelete,
          .taskBoardSync,
          .taskBoardDispatch,
          .taskBoardAudit,
        ]
    )
    #expect(objectValue(calls[0].params, key: "status") == .string("todo"))
    #expect(objectValue(calls[1].params, key: "id") == .string("board-1"))
    #expect(objectValue(calls[3].params, key: "id") == .string("board-1"))
    #expect(objectValue(calls[3].params, key: "status") == .string("done"))
    #expect(objectValue(calls[6].params, key: "status") == .string("todo"))
    #expect(objectValue(calls[6].params, key: "dry_run") == .bool(false))
    #expect(objectValue(calls[6].params, key: "project_dir") == .string("/tmp/harness"))
    #expect(objectValue(calls[7].params, key: "status") == .string("blocked"))
    #expect(dispatch.plans.first?.task.title == "Board item")
    #expect(dispatch.plans.first?.policy?.decision == "allow")
    #expect(dispatch.applied.first?.workItemId == "task-1")
  }

  private func makeClient() throws -> HarnessMonitorAPIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TaskBoardURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: try #require(URL(string: "http://127.0.0.1:9999")),
        token: "token"
      ),
      session: session
    )
  }

  private func objectValue(_ value: JSONValue?, key: String) -> JSONValue? {
    guard case .object(let object)? = value else {
      return nil
    }
    return object[key]
  }
}

private actor RPCProbe {
  struct Call: Sendable {
    let method: WebSocketRPCMethod
    let params: JSONValue?
  }

  private(set) var calls: [Call] = []

  func record(method: WebSocketRPCMethod, params: JSONValue?) {
    calls.append(Call(method: method, params: params))
  }
}

private final class TaskBoardURLProtocol: URLProtocol, @unchecked Sendable {
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
    if path == "/v1/task-board/audit" {
      return #"{"total":1,"ready":1,"blocked":0,"deleted":0,"by_status":[]}"#
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
