import XCTest

@testable import HarnessMonitorE2ECore

final class AllocatePortTests: XCTestCase {
  func testAllocatesNonZeroEphemeralPort() throws {
    let port = try PortAllocator.allocateLocalTCPPort()
    XCTAssertGreaterThan(port, 0)
    XCTAssertGreaterThanOrEqual(port, 1024, "kernel should hand out an unprivileged port")
  }

  func testRepeatedAllocationsAreIndependent() throws {
    // Two consecutive bindings can land on the same port if the kernel reuses it,
    // but each call individually must return a valid port.
    let first = try PortAllocator.allocateLocalTCPPort()
    let second = try PortAllocator.allocateLocalTCPPort()
    XCTAssertGreaterThan(first, 0)
    XCTAssertGreaterThan(second, 0)
  }
}
