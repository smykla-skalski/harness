import XCTest

@testable import HarnessMonitorKit

final class URLSecurityScopeTests: XCTestCase {
  func testSyncBodyReceivesSameURL() throws {
    let tmp = FileManager.default.temporaryDirectory
    let received = try tmp.withSecurityScope { $0 }
    XCTAssertEqual(received, tmp)
  }

  func testSyncBodyStopsOnThrow() {
    struct Boom: Error {}
    let tmp = FileManager.default.temporaryDirectory
    XCTAssertThrowsError(
      try tmp.withSecurityScope { _ in throw Boom() }
    ) { error in
      XCTAssertTrue(error is Boom)
    }
  }

  func testAsyncBodyReceivesSameURL() async throws {
    let tmp = FileManager.default.temporaryDirectory
    let received = try await tmp.withSecurityScopeAsync { $0 }
    XCTAssertEqual(received, tmp)
  }

  func testAsyncBodyStopsOnThrow() async {
    struct Boom: Error {}
    let tmp = FileManager.default.temporaryDirectory
    do {
      try await tmp.withSecurityScopeAsync { _ in throw Boom() }
      XCTFail("expected throw")
    } catch is Boom {
      // expected
    } catch {
      XCTFail("wrong error: \(error)")
    }
  }
}
