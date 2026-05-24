import XCTest

@testable import HarnessMonitorE2ECore

final class ConfigureXctestrunTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("xctestrun-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  func testInjectsEnvVarsIntoBothEnvironmentDictionaries() throws {
    let source = tempDir.appendingPathComponent("source.xctestrun")
    let destination = tempDir.appendingPathComponent("dest.xctestrun")
    let original: [String: Any] = [
      "HarnessMonitorAgentsE2ETests": [
        "EnvironmentVariables": ["EXISTING_VAR": "keep"],
        "TestingEnvironmentVariables": ["DYLD_VAR": "leave"],
      ] as [String: Any]
    ]
    let originalData = try PropertyListSerialization.data(
      fromPropertyList: original, format: .xml, options: 0
    )
    try originalData.write(to: source)

    let updates: [String: String] = [
      "HARNESS_MONITOR_E2E_STATE_ROOT": "/tmp/state",
      "HARNESS_MONITOR_ENABLE_AGENTS_E2E": "1",
    ]
    try XctestrunConfigurator.configure(
      source: source, destination: destination, updates: updates
    )

    let mutated =
      try PropertyListSerialization.propertyList(
        from: try Data(contentsOf: destination), format: nil
      ) as? [String: Any]
    let target = try XCTUnwrap(mutated?["HarnessMonitorAgentsE2ETests"] as? [String: Any])
    for key in XctestrunConfigurator.environmentKeys {
      let env = try XCTUnwrap(target[key] as? [String: String])
      XCTAssertEqual(env["HARNESS_MONITOR_E2E_STATE_ROOT"], "/tmp/state")
      XCTAssertEqual(env["HARNESS_MONITOR_ENABLE_AGENTS_E2E"], "1")
    }
    let env = try XCTUnwrap(target["EnvironmentVariables"] as? [String: String])
    XCTAssertEqual(env["EXISTING_VAR"], "keep", "must preserve existing values")
  }

  func testFailsWhenTargetMissing() throws {
    let source = tempDir.appendingPathComponent("source.xctestrun")
    let destination = tempDir.appendingPathComponent("dest.xctestrun")
    let payload: [String: Any] = ["WrongTarget": [:] as [String: Any]]
    try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
      .write(to: source)

    XCTAssertThrowsError(
      try XctestrunConfigurator.configure(
        source: source, destination: destination, updates: ["A": "B"]
      )
    )
  }

  func testCustomTargetKeyIsRespected() throws {
    let source = tempDir.appendingPathComponent("source.xctestrun")
    let destination = tempDir.appendingPathComponent("dest.xctestrun")
    let payload: [String: Any] = [
      "OtherTarget": [
        "EnvironmentVariables": [:] as [String: Any],
        "TestingEnvironmentVariables": [:] as [String: Any],
      ] as [String: Any]
    ]
    try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
      .write(to: source)

    try XctestrunConfigurator.configure(
      source: source, destination: destination,
      targetKey: "OtherTarget", updates: ["X": "Y"]
    )

    let mutated =
      try PropertyListSerialization.propertyList(
        from: try Data(contentsOf: destination), format: nil
      ) as? [String: Any]
    let target = try XCTUnwrap(mutated?["OtherTarget"] as? [String: Any])
    let env = try XCTUnwrap(target["EnvironmentVariables"] as? [String: String])
    XCTAssertEqual(env["X"], "Y")
  }
}
