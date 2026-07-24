import Foundation
import XCTest

@testable import HarnessMonitorKit

final class RepositoryDirectoryStoreTests: XCTestCase {
  func testAssociateThenLookup() async throws {
    let dir = try makeTempDir()
    let store = RepositoryDirectoryStore(containerURL: dir)

    try await store.associate(repository: "smykla-skalski/harness", bookmarkID: "B-1")

    let resolved = await store.bookmarkID(forRepository: "smykla-skalski/harness")
    XCTAssertEqual(resolved, "B-1")
  }

  func testLookupNormalizesWhitespaceAndCase() async throws {
    let dir = try makeTempDir()
    let store = RepositoryDirectoryStore(containerURL: dir)

    try await store.associate(repository: "  Smykla-Skalski/Harness  ", bookmarkID: "B-2")

    let resolved = await store.bookmarkID(forRepository: "smykla-skalski/harness")
    XCTAssertEqual(resolved, "B-2")
    let associations = await store.allAssociations()
    XCTAssertEqual(associations.map(\.repository), ["smykla-skalski/harness"])
  }

  func testAssociateOverwritesSameRepository() async throws {
    let dir = try makeTempDir()
    let store = RepositoryDirectoryStore(containerURL: dir)

    try await store.associate(repository: "acme/widgets", bookmarkID: "B-old")
    try await store.associate(repository: "acme/widgets", bookmarkID: "B-new")

    let resolved = await store.bookmarkID(forRepository: "acme/widgets")
    XCTAssertEqual(resolved, "B-new")
    let associations = await store.allAssociations()
    XCTAssertEqual(associations.count, 1)
  }

  func testPersistsAcrossReinit() async throws {
    let dir = try makeTempDir()
    try await RepositoryDirectoryStore(containerURL: dir)
      .associate(repository: "acme/widgets", bookmarkID: "B-3")

    let reloaded = RepositoryDirectoryStore(containerURL: dir)
    let resolved = await reloaded.bookmarkID(forRepository: "acme/widgets")
    XCTAssertEqual(resolved, "B-3")
  }

  func testRemoveAssociation() async throws {
    let dir = try makeTempDir()
    let store = RepositoryDirectoryStore(containerURL: dir)
    try await store.associate(repository: "acme/widgets", bookmarkID: "B-4")

    try await store.removeAssociation(forRepository: "ACME/Widgets")

    let resolved = await store.bookmarkID(forRepository: "acme/widgets")
    XCTAssertNil(resolved)
    let associations = await store.allAssociations()
    XCTAssertTrue(associations.isEmpty)
  }

  func testAllAssociationsSortedByRepository() async throws {
    let dir = try makeTempDir()
    let store = RepositoryDirectoryStore(containerURL: dir)
    try await store.associate(repository: "zeta/one", bookmarkID: "B-z")
    try await store.associate(repository: "alpha/two", bookmarkID: "B-a")

    let associations = await store.allAssociations()
    XCTAssertEqual(associations.map(\.repository), ["alpha/two", "zeta/one"])
  }

  func testEmptyRepositoryLookupReturnsNil() async throws {
    let dir = try makeTempDir()
    let store = RepositoryDirectoryStore(containerURL: dir)
    let resolved = await store.bookmarkID(forRepository: "   ")
    XCTAssertNil(resolved)
  }

  func testUnsupportedSchemaVersionRefusesMutation() async throws {
    let dir = try makeTempDir()
    let sandboxDir = dir.appendingPathComponent("sandbox", isDirectory: true)
    try FileManager.default.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
    let url = sandboxDir.appendingPathComponent("repository-directories.json")
    try Data(#"{"schemaVersion": 99, "associations": []}"#.utf8).write(to: url)

    let store = RepositoryDirectoryStore(containerURL: dir)
    // Reading a future-schema file serves empty rather than clobbering it.
    let associations = await store.allAssociations()
    XCTAssertTrue(associations.isEmpty)
    // Mutating a file it cannot understand must fail rather than overwrite it.
    do {
      try await store.associate(repository: "acme/widgets", bookmarkID: "B-5")
      XCTFail("expected unsupported schema to block mutation")
    } catch {
      // expected
    }
  }

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepositoryDirectoryStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}
