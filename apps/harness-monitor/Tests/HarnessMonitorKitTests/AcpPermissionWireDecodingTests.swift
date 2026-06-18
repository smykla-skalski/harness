import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the acp permission batch/item. The batch wire is generated
/// from the owned AcpPermissionBatchDecode (the public type carries no serde derive); the item
/// models tool_call and the external-crate permission options as raw JSONValue. The map applies
/// the managed_agent_id -> acpId cross-rename and the dropped managed_agent_family is decode-safe.
/// These feed AcpAgentSnapshot.pendingPermissionBatches in the managed-agents graph.
@Suite("Acp permission wire type")
struct AcpPermissionWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a permission batch, ignoring the dropped family field")
  func decodesBatch() throws {
    let wire = try decoder.decode(
      AcpPermissionBatchWire.self, from: Data(batchFixture.utf8)
    )
    #expect(wire.batchId == "batch-1")
    #expect(wire.managedAgentId == "acp-1")
    #expect(wire.expiresAt == "2026-06-18T00:05:00Z")
    let request = try #require(wire.requests.first)
    #expect(request.requestId == "req-1")
    #expect(request.options.count == 2)
    if case .object(let toolCall) = request.toolCall {
      #expect(toolCall["name"] == .string("fs_write"))
    } else {
      Issue.record("expected an object tool call")
    }
  }

  @Test("maps a permission batch with the cross-renamed acp id")
  func mapsBatch() throws {
    let wire = try decoder.decode(
      AcpPermissionBatchWire.self, from: Data(batchFixture.utf8)
    )
    let batch = AcpPermissionBatch(wire: wire)
    #expect(batch.id == "batch-1")
    #expect(batch.acpId == "acp-1")
    #expect(batch.sessionId == "sess-1")
    #expect(batch.expiresAt == "2026-06-18T00:05:00Z")
    let request = try #require(batch.requests.first)
    #expect(request.requestId == "req-1")
    #expect(request.options.count == 2)
  }
}

private let batchFixture = """
  {
    "batch_id": "batch-1",
    "managed_agent_id": "acp-1",
    "managed_agent_family": "acp",
    "session_id": "sess-1",
    "requests": [
      {
        "request_id": "req-1",
        "session_id": "sess-1",
        "tool_call": { "name": "fs_write", "path": "/tmp/x" },
        "options": [
          { "id": "allow", "label": "Allow" },
          { "id": "deny", "label": "Deny" }
        ]
      }
    ],
    "created_at": "2026-06-18T00:00:00Z",
    "expires_at": "2026-06-18T00:05:00Z"
  }
  """
