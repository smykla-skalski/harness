import XCTest

/// Single-launch XCUITest companion for `scripts/e2e/swarm-full-flow.sh`.
/// The shell driver performs each CLI-side act, writes `<act>.ready`, then
/// this runner asserts the corresponding Monitor surface and writes `<act>.ack`.
@MainActor
final class SwarmFullFlowTests: HarnessMonitorUITestCase {
  func testSwarmFullFlow() throws {
    let fixture = try SwarmFixture(testCase: self)
    fixture.launch()

    let runner = SwarmRunner(fixture: fixture)
    try runner.act1()
    try runner.act2()
    try runner.act3()
    try runner.act4()
    try runner.act5()
    try runner.act6()
    try runner.act7()
    try runner.act8()
    try runner.act9()
    try runner.act10()
    try runner.act11()
    try runner.act12()
    try runner.act13()
    try runner.act14()
    try runner.act15()
    try runner.act16()
  }
}
