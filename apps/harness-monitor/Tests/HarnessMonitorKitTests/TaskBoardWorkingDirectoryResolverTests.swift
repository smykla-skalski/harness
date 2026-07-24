import Foundation
import XCTest

@testable import HarnessMonitorKit

final class TaskBoardWorkingDirectoryResolverTests: XCTestCase {
  private typealias Resolver = TaskBoardWorkingDirectoryResolver

  func testExistingSessionNeedsNoDirectory() {
    let decision = Resolver.decide(
      hasExistingSession: true,
      executionRepository: "acme/widgets",
      associatedProjectDir: nil,
      globalProjectDir: "/tmp/global"
    )
    XCTAssertEqual(decision, .dispatch(projectDir: nil))
  }

  func testImportedItemWithAssociationDispatchesIt() {
    let decision = Resolver.decide(
      hasExistingSession: false,
      executionRepository: "acme/widgets",
      associatedProjectDir: "B-bookmark",
      globalProjectDir: "/tmp/global"
    )
    XCTAssertEqual(decision, .dispatch(projectDir: "B-bookmark"))
  }

  func testImportedItemWithoutAssociationNeedsWorkingDirectory() {
    let decision = Resolver.decide(
      hasExistingSession: false,
      executionRepository: "  Acme/Widgets  ",
      associatedProjectDir: nil,
      globalProjectDir: "/tmp/global"
    )
    XCTAssertEqual(decision, .needsWorkingDirectory(repository: "acme/widgets"))
  }

  func testCreateItemWithoutRepositoryFallsBackToGlobal() {
    let decision = Resolver.decide(
      hasExistingSession: false,
      executionRepository: nil,
      associatedProjectDir: nil,
      globalProjectDir: "/tmp/global"
    )
    XCTAssertEqual(decision, .dispatch(projectDir: "/tmp/global"))
  }

  func testUnresolvedRepositoriesDedupesAndSorts() {
    let items = [
      Resolver.ItemNeed(hasExistingSession: false, executionRepository: "zeta/one"),
      Resolver.ItemNeed(hasExistingSession: false, executionRepository: "Zeta/One"),
      Resolver.ItemNeed(hasExistingSession: false, executionRepository: "alpha/two"),
      Resolver.ItemNeed(hasExistingSession: true, executionRepository: "gamma/three"),
      Resolver.ItemNeed(hasExistingSession: false, executionRepository: nil),
    ]
    let unresolved = Resolver.unresolvedRepositories(items: items) { _ in false }
    XCTAssertEqual(unresolved, ["alpha/two", "zeta/one"])
  }

  func testUnresolvedRepositoriesSkipsAssociated() {
    let items = [
      Resolver.ItemNeed(hasExistingSession: false, executionRepository: "acme/widgets"),
      Resolver.ItemNeed(hasExistingSession: false, executionRepository: "other/repo"),
    ]
    let unresolved = Resolver.unresolvedRepositories(items: items) { repo in
      repo == "acme/widgets"
    }
    XCTAssertEqual(unresolved, ["other/repo"])
  }
}
