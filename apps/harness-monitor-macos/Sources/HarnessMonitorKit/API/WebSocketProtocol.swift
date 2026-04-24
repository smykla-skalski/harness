import Foundation
import Synchronization

struct WsRequest: Codable, Sendable {
  let id: String
  let method: String
  let params: JSONValue?
  let traceContext: [String: String]?

  init(
    id: String,
    method: String,
    params: JSONValue?,
    traceContext: [String: String]? = nil
  ) {
    self.id = id
    self.method = method
    self.params = params
    self.traceContext = traceContext
  }
}

struct WsFrame: Codable, Sendable {
  let id: String?
  let result: JSONValue?
  let error: WsErrorPayload?
  let batchIndex: Int?
  let batchCount: Int?
  let event: String?
  let recordedAt: String?
  let sessionId: String?
  let payload: JSONValue?
  let seq: UInt64?
  let chunkId: String?
  let chunkIndex: Int?
  let chunkCount: Int?
  let chunkBase64: String?
}

struct WsErrorPayload: Codable, Sendable {
  let code: String
  let message: String
  let details: [String]?
  let statusCode: Int?
  let data: JSONValue?
}

enum WebSocketRPCMethod: String, CaseIterable, Equatable, Sendable {
  case ping = "ping"
  case health = "health"
  case diagnostics = "diagnostics"
  case daemonStop = "daemon.stop"
  case bridgeReconfigure = "bridge.reconfigure"
  case daemonLogLevel = "daemon.log_level"
  case daemonSetLogLevel = "daemon.set_log_level"
  case projects = "projects"
  case sessions = "sessions"
  case runtimeSessionResolve = "runtime_session.resolve"
  case streamSubscribe = "stream.subscribe"
  case streamUnsubscribe = "stream.unsubscribe"
  case sessionDetail = "session.detail"
  case sessionTimeline = "session.timeline"
  case sessionSubscribe = "session.subscribe"
  case sessionUnsubscribe = "session.unsubscribe"
  case sessionStart = "session.start"
  case sessionAdopt = "session.adopt"
  case sessionDelete = "session.delete"
  case sessionJoin = "session.join"
  case sessionRuntimeSession = "session.runtime_session"
  case sessionTitle = "session.title"
  case sessionEnd = "session.end"
  case sessionLeave = "session.leave"
  case signalSend = "signal.send"
  case signalCancel = "signal.cancel"
  case signalAck = "signal.ack"
  case sessionObserve = "session.observe"
  case sessionManagedAgents = "session.managed_agents"
  case managedAgentDetail = "managed_agent.detail"
  case taskCreate = "task.create"
  case taskAssign = "task.assign"
  case taskDrop = "task.drop"
  case taskQueuePolicy = "task.queue_policy"
  case taskUpdate = "task.update"
  case taskCheckpoint = "task.checkpoint"
  case taskSubmitForReview = "task.submit_for_review"
  case taskClaimReview = "task.claim_review"
  case taskSubmitReview = "task.submit_review"
  case taskRespondReview = "task.respond_review"
  case taskArbitrate = "task.arbitrate"
  case improverApply = "improver.apply"
  case agentChangeRole = "agent.change_role"
  case agentRemove = "agent.remove"
  case leaderTransfer = "leader.transfer"
  case managedAgentStartTerminal = "managed_agent.start_terminal"
  case managedAgentStartCodex = "managed_agent.start_codex"
  case managedAgentInput = "managed_agent.input"
  case managedAgentResize = "managed_agent.resize"
  case managedAgentStop = "managed_agent.stop"
  case managedAgentReady = "managed_agent.ready"
  case managedAgentSteerCodex = "managed_agent.steer_codex"
  case managedAgentInterruptCodex = "managed_agent.interrupt_codex"
  case managedAgentResolveCodexApproval = "managed_agent.resolve_codex_approval"
  case voiceStartSession = "voice.start_session"
  case voiceAppendAudio = "voice.append_audio"
  case voiceAppendTranscript = "voice.append_transcript"
  case voiceFinishSession = "voice.finish_session"
}

typealias ResponseBatchHandler =
  @Sendable (_ batchIndex: Int, _ batchCount: Int, _ result: JSONValue?) async throws -> Void

enum WsFrameKind {
  case response(
    id: String,
    result: JSONValue?,
    error: WsErrorPayload?,
    batchIndex: Int?,
    batchCount: Int?
  )
  case push(event: String, recordedAt: String, sessionId: String?, payload: JSONValue, seq: UInt64)
  case chunk(id: String, index: Int, count: Int, base64: String)
  case unknown
}

extension WsFrame {
  var kind: WsFrameKind {
    if let chunkId, let chunkIndex, let chunkCount, let chunkBase64 {
      return .chunk(id: chunkId, index: chunkIndex, count: chunkCount, base64: chunkBase64)
    }
    let hasResponseFields = result != nil || error != nil
    if let id, hasResponseFields {
      return .response(
        id: id,
        result: result,
        error: error,
        batchIndex: batchIndex,
        batchCount: batchCount
      )
    }
    if let event, let recordedAt, let payload {
      return .push(
        event: event,
        recordedAt: recordedAt,
        sessionId: sessionId,
        payload: payload,
        seq: seq ?? 0
      )
    }
    return .unknown
  }
}

struct PendingResponseBatches: Sendable {
  let expectedCount: Int
  var batches: [[JSONValue]?]
  var receivedCount: Int = 0

  init(expectedCount: Int) {
    self.expectedCount = expectedCount
    self.batches = Array(repeating: nil, count: expectedCount)
  }

  mutating func append(
    index: Int,
    count: Int,
    result: JSONValue?
  ) throws -> JSONValue? {
    guard count == expectedCount else {
      throw WebSocketTransportError.invalidBatch("batch count changed during assembly")
    }
    guard batches.indices.contains(index) else {
      throw WebSocketTransportError.invalidBatch("batch index out of bounds")
    }
    guard case .array(let entries)? = result else {
      throw WebSocketTransportError.invalidBatch("semantic batch payload must be an array")
    }

    if batches[index] == nil {
      batches[index] = entries
      receivedCount += 1
    }

    guard receivedCount == expectedCount else {
      return nil
    }

    var assembled: [JSONValue] = []
    assembled.reserveCapacity(
      batches.reduce(into: 0) { partialResult, batch in
        partialResult += batch?.count ?? 0
      }
    )
    for batch in batches {
      guard let batch else {
        throw WebSocketTransportError.invalidBatch("batch assembly completed with gaps")
      }
      assembled.append(contentsOf: batch)
    }
    return .array(assembled)
  }
}

struct PendingFrameChunks: Sendable {
  let expectedCount: Int
  var chunks: [Data?]
  var receivedCount: Int = 0

  init(expectedCount: Int) {
    self.expectedCount = expectedCount
    self.chunks = Array(repeating: nil, count: expectedCount)
  }

  mutating func append(index: Int, count: Int, base64: String) throws -> Data? {
    guard count == expectedCount else {
      throw WebSocketTransportError.invalidChunk("chunk count changed during assembly")
    }
    guard chunks.indices.contains(index) else {
      throw WebSocketTransportError.invalidChunk("chunk index out of bounds")
    }
    guard let decoded = Data(base64Encoded: base64) else {
      throw WebSocketTransportError.invalidChunk("chunk payload is not valid base64")
    }

    if chunks[index] == nil {
      chunks[index] = decoded
      receivedCount += 1
    }

    guard receivedCount == expectedCount else {
      return nil
    }

    var assembled = Data()
    for chunk in chunks {
      guard let chunk else {
        throw WebSocketTransportError.invalidChunk("chunk assembly completed with gaps")
      }
      assembled.append(chunk)
    }
    return assembled
  }
}

private struct PendingRequestEntry {
  let continuation: CheckedContinuation<JSONValue, any Error>
  var responseBatches: PendingResponseBatches?
}

final class PendingRequestStore: Sendable {
  private let storage = Mutex<[String: PendingRequestEntry]>([:])

  func register(id: String, continuation: CheckedContinuation<JSONValue, any Error>) {
    storage.withLock {
      $0[id] = PendingRequestEntry(continuation: continuation, responseBatches: nil)
    }
  }

  func resume(id: String, result: JSONValue) {
    let entry = storage.withLock { $0.removeValue(forKey: id) }
    entry?.continuation.resume(returning: result)
  }

  func resumeBatch(
    id: String,
    index: Int,
    count: Int,
    result: JSONValue?
  ) throws -> Bool {
    var completed: (CheckedContinuation<JSONValue, any Error>, JSONValue)?
    var failed: (CheckedContinuation<JSONValue, any Error>, any Error)?

    storage.withLock { storage in
      guard var entry = storage[id] else {
        return
      }
      var batches = entry.responseBatches ?? PendingResponseBatches(expectedCount: count)
      do {
        let assembled = try batches.append(index: index, count: count, result: result)
        if let assembled {
          storage.removeValue(forKey: id)
          completed = (entry.continuation, assembled)
        } else {
          entry.responseBatches = batches
          storage[id] = entry
        }
      } catch {
        storage.removeValue(forKey: id)
        failed = (entry.continuation, error)
      }
    }

    if let (continuation, result) = completed {
      continuation.resume(returning: result)
      return true
    }
    if let (continuation, error) = failed {
      continuation.resume(throwing: error)
      throw error
    }
    return false
  }

  func fail(id: String, error: any Error) {
    let entry = storage.withLock { $0.removeValue(forKey: id) }
    entry?.continuation.resume(throwing: error)
  }

  func failAll(error: any Error) {
    let pending = storage.withLock {
      let all = $0
      $0.removeAll()
      return all
    }
    for (_, entry) in pending {
      entry.continuation.resume(throwing: error)
    }
  }
}

enum WebSocketTransportError: LocalizedError {
  case serverError(code: String, message: String)
  case connectionClosed
  case upgradeRejected
  case unexpectedResponse
  case invalidChunk(String)
  case invalidBatch(String)

  var errorDescription: String? {
    switch self {
    case .serverError(_, let message): message
    case .connectionClosed: "WebSocket connection closed"
    case .upgradeRejected: "WebSocket upgrade rejected by server"
    case .unexpectedResponse: "Unexpected response from server"
    case .invalidChunk(let message): "Invalid WebSocket chunk: \(message)"
    case .invalidBatch(let message): "Invalid WebSocket response batch: \(message)"
    }
  }
}
