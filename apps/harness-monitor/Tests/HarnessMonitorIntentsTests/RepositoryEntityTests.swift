import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

final class RepositoryEntityTests: XCTestCase {
  func testRawIdentifierInitParsesOwnerAndName() {
    let entity = RepositoryEntity(rawIdentifier: "octo/Hello-World")

    XCTAssertNotNil(entity)
    XCTAssertEqual(entity?.id, "octo/Hello-World")
    XCTAssertEqual(entity?.owner, "octo")
    XCTAssertEqual(entity?.name, "Hello-World")
  }

  func testRawIdentifierInitTrimsWhitespace() {
    let entity = RepositoryEntity(rawIdentifier: "  octo/Hello-World  ")

    XCTAssertEqual(entity?.id, "octo/Hello-World")
  }

  func testRawIdentifierInitRejectsMissingSlash() {
    XCTAssertNil(RepositoryEntity(rawIdentifier: "octo"))
  }

  func testRawIdentifierInitRejectsEmptyOwnerOrName() {
    XCTAssertNil(RepositoryEntity(rawIdentifier: "/Hello-World"))
    XCTAssertNil(RepositoryEntity(rawIdentifier: "octo/"))
    XCTAssertNil(RepositoryEntity(rawIdentifier: "/"))
    XCTAssertNil(RepositoryEntity(rawIdentifier: ""))
  }

  func testRawIdentifierInitAllowsSlashesInNameOnceOnly() {
    let entity = RepositoryEntity(rawIdentifier: "octo/sub/repo")

    XCTAssertEqual(entity?.owner, "octo")
    XCTAssertEqual(entity?.name, "sub/repo")
    XCTAssertEqual(entity?.id, "octo/sub/repo")
  }
}
