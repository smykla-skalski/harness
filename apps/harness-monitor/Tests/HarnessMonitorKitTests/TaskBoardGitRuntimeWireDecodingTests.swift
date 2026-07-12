import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the git runtime config tree (runtime-config get/update +
/// secret-handoff). Generated from runtime_config.rs + daemon/protocol/task_board.rs; the signing
/// mode rides bare through the decoder-agnostic TaskBoardGitSigningMode open enum and the
/// *_configured wire indicators carry across the global profile and the repository overrides.
@Suite("Task board git runtime wire decoding")
struct TaskBoardGitRuntimeWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("runtime config maps the global profile, signing config and the repository override")
  func runtimeConfigMapping() throws {
    let payload = #"""
      {
        "global": {
          "author_name": "Ada", "author_email": "ada@example.com",
          "ssh_key_path": "/keys/id_ed25519", "ssh_private_key_configured": true,
          "signing": {
            "mode": "ssh", "ssh_key_path": "/keys/sign",
            "ssh_private_key_configured": true, "gpg_key_id": "ABC123"
          }
        },
        "repository_overrides": [
          {
            "repository": "acme/widget",
            "profile": {
              "author_email": "bot@example.com",
              "signing": {"mode": "gpg", "gpg_private_key_configured": true}
            }
          }
        ]
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(TaskBoardGitRuntimeConfigWire.self, from: data)
    let config = TaskBoardGitRuntimeConfig(wire: wire)

    #expect(config.global.authorName == "Ada")
    #expect(config.global.sshKeyPath == "/keys/id_ed25519")
    #expect(config.global.sshPrivateKeyConfigured == true)
    #expect(config.global.signing.mode == .ssh)
    #expect(config.global.signing.gpgKeyId == "ABC123")
    #expect(config.global.signing.sshPrivateKeyConfigured == true)
    #expect(config.repositoryOverrides.count == 1)
    #expect(config.repositoryOverrides.first?.repository == "acme/widget")
    #expect(config.repositoryOverrides.first?.profile.signing.mode == .gpg)
    #expect(config.repositoryOverrides.first?.profile.signing.gpgPrivateKeyConfigured == true)
  }

  @Test("secret-handoff prepare maps identity, digest and nested runtime config")
  func secretHandoffPrepareMapping() throws {
    let payload = #"""
      {
        "prepared": true,
        "migration_id": "migration-1",
        "digest": "abc123",
        "runtime": {
          "global": {"ssh_private_key": "secret-bytes", "signing": {"mode": "none"}},
          "repository_overrides": []
        }
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(
      TaskBoardGitRuntimeSecretHandoffPrepareResponseWire.self,
      from: data
    )
    let response = TaskBoardGitRuntimeSecretHandoffPrepareResponse(wire: wire)

    #expect(response.prepared == true)
    #expect(response.migrationID == "migration-1")
    #expect(response.digest == "abc123")
    #expect(response.runtime.global.sshPrivateKey == "secret-bytes")
    #expect(response.runtime.global.signing.mode == .none)
    #expect(response.runtime.repositoryOverrides.isEmpty)
  }
}
