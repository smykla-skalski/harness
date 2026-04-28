import HarnessMonitorKit
import XCTest

final class AcpAgentDescriptorTests: XCTestCase {
  func testDescriptorRoundTripsFromSnakeCaseConfigPayload() throws {
    let json = Data(
      """
      {
        "id": "copilot",
        "display_name": "GitHub Copilot",
        "capabilities": ["fs.read", "fs.write", "terminal.spawn"],
        "launch_command": "copilot",
        "launch_args": ["--acp", "--stdio"],
        "env_passthrough": ["GH_TOKEN"],
        "install_hint": "Install GitHub Copilot CLI.",
        "doctor_probe": {
          "command": "copilot",
          "args": ["--version"]
        }
      }
      """.utf8
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let descriptor = try decoder.decode(AcpAgentDescriptor.self, from: json)

    XCTAssertEqual(descriptor.id, "copilot")
    XCTAssertEqual(descriptor.displayName, "GitHub Copilot")
    XCTAssertEqual(descriptor.launchArgs, ["--acp", "--stdio"])
    XCTAssertEqual(descriptor.doctorProbe.command, "copilot")
  }

  func testConfigurationDefaultsAcpFields() throws {
    let json = Data(
      """
      {
        "personas": [],
        "runtime_models": []
      }
      """.utf8
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let configuration = try decoder.decode(MonitorConfiguration.self, from: json)

    XCTAssertTrue(configuration.acpAgents.isEmpty)
    XCTAssertNil(configuration.runtimeProbe)
  }
}
