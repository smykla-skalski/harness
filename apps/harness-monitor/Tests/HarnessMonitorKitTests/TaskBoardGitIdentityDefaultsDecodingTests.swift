import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the `/v1/task-board/git/identity-defaults`
/// response. The daemon serializes `TaskBoardGitIdentityDefaults`
/// (src/task_board/git_identity_defaults.rs) with plain serde snake_case, and
/// the shared client decodes every response with
/// `keyDecodingStrategy = .convertFromSnakeCase`. A hand-written model that
/// also spells explicit snake_case `CodingKeys` raw values is mutually
/// exclusive with that strategy: the strategy rewrites the JSON key
/// `git_config` to `gitConfig` before matching, so a coding key whose literal
/// value is `git_config` never matches and the field drops out (or, for a
/// non-optional field, the decode throws `keyNotFound`).
@Suite("Task board git identity defaults decoding")
struct TaskBoardGitIdentityDefaultsDecodingTests {
  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  /// Byte-for-byte daemon payload (snake_case wire keys, `null` for absent
  /// optionals because the Rust fields carry no `skip_serializing_if`).
  private let daemonPayload = """
    {
      "git_config": {
        "user_name": "Ada Lovelace",
        "user_email": "ada@example.com",
        "user_signingkey": "ABCD1234",
        "gpg_format": "ssh",
        "commit_gpgsign": true,
        "core_ssh_command": "ssh -i ~/.ssh/id_ed25519"
      },
      "gh_cli": {
        "github_token_present": true,
        "username": "ada"
      },
      "discovered_ssh_keys": [
        {
          "path": "/Users/ada/.ssh/id_ed25519.pub",
          "mode": "0600",
          "format": "ssh-ed25519",
          "warning": null
        }
      ],
      "env_overrides": {
        "harness_github_token_present": true,
        "harness_todoist_token_present": false
      }
    }
    """

  @Test("decodes the daemon git-config block through the shared snake-case decoder")
  func decodesGitConfigBlock() throws {
    let defaults = try decoder.decode(
      TaskBoardGitIdentityDefaults.self,
      from: Data(daemonPayload.utf8)
    )

    #expect(defaults.gitConfig.userName == "Ada Lovelace")
    #expect(defaults.gitConfig.userEmail == "ada@example.com")
    #expect(defaults.gitConfig.userSigningkey == "ABCD1234")
    #expect(defaults.gitConfig.gpgFormat == "ssh")
    #expect(defaults.gitConfig.commitGpgsign == true)
    #expect(defaults.gitConfig.coreSshCommand == "ssh -i ~/.ssh/id_ed25519")
  }

  @Test("decodes the gh-cli, ssh-key, and env-override blocks")
  func decodesRemainingBlocks() throws {
    let defaults = try decoder.decode(
      TaskBoardGitIdentityDefaults.self,
      from: Data(daemonPayload.utf8)
    )

    #expect(defaults.ghCli.githubTokenPresent == true)
    #expect(defaults.ghCli.username == "ada")
    #expect(defaults.discoveredSshKeys.count == 1)
    #expect(defaults.discoveredSshKeys.first?.path == "/Users/ada/.ssh/id_ed25519.pub")
    #expect(defaults.discoveredSshKeys.first?.format == "ssh-ed25519")
    #expect(defaults.envOverrides.harnessGithubTokenPresent == true)
    #expect(defaults.envOverrides.harnessTodoistTokenPresent == false)
  }

  @Test("round-trips back to the daemon snake_case wire keys")
  func roundTripsToWireKeys() throws {
    let defaults = try decoder.decode(
      TaskBoardGitIdentityDefaults.self,
      from: Data(daemonPayload.utf8)
    )

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let reencoded = try encoder.encode(defaults)
    let object = try #require(
      try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
    )

    #expect(object["git_config"] != nil)
    #expect(object["gh_cli"] != nil)
    #expect(object["discovered_ssh_keys"] != nil)
    #expect(object["env_overrides"] != nil)
    let gitConfig = try #require(object["git_config"] as? [String: Any])
    #expect(gitConfig["user_name"] as? String == "Ada Lovelace")
    #expect(gitConfig["core_ssh_command"] as? String == "ssh -i ~/.ssh/id_ed25519")
  }
}
