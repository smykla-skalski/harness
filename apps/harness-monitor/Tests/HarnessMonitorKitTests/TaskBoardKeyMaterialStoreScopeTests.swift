import Testing

@testable import HarnessMonitorKit

@Suite("TaskBoardKeyMaterialStore.Scope account identifiers")
struct TaskBoardKeyMaterialStoreScopeTests {
  @Test("Global scope account is the literal string global")
  func globalScopeAccountIsLiteral() {
    #expect(TaskBoardKeyMaterialStore.Scope.global.account == "global")
  }

  @Test("Repository scope account is a stable SHA-1 hex digest, case-insensitive")
  func repositoryScopeAccountIsStableSHA1Hex() {
    let lower = TaskBoardKeyMaterialStore.Scope.repository("owner/repo").account
    let upper = TaskBoardKeyMaterialStore.Scope.repository("OWNER/REPO").account
    #expect(lower == upper)

    let expectedSHA1OfOwnerRepo = "b0a93768b870824e04990d714ca1b761394528c1"
    #expect(lower == "repo" + expectedSHA1OfOwnerRepo)
  }

  @Test("Distinct repositories produce distinct accounts")
  func distinctRepositoriesProduceDistinctAccounts() {
    let one = TaskBoardKeyMaterialStore.Scope.repository("acme/widgets").account
    let two = TaskBoardKeyMaterialStore.Scope.repository("acme/gizmos").account
    #expect(one != two)
  }

  @Test("Database repository scope normalizes repository case")
  func databaseRepositoryScopeNormalizesRepositoryCase() {
    let lower = TaskBoardKeyMaterialStore.Scope.databaseRepository(
      "database-a",
      "owner/repo"
    ).account
    let upper = TaskBoardKeyMaterialStore.Scope.databaseRepository(
      "database-a",
      "OWNER/REPO"
    ).account
    #expect(lower == upper)
  }

  @Test("Database scopes cannot collide")
  func databaseScopesAreDistinct() {
    #expect(
      TaskBoardKeyMaterialStore.Scope.databaseGlobal("database-a").account
        != TaskBoardKeyMaterialStore.Scope.databaseGlobal("database-b").account
    )
    #expect(
      TaskBoardKeyMaterialStore.Scope.databaseGlobal("database-a").account
        != TaskBoardKeyMaterialStore.Scope.databaseGlobal("DATABASE-A").account
    )
    #expect(
      TaskBoardKeyMaterialStore.Scope.databaseRepository("database-a", "owner/repo").account
        != TaskBoardKeyMaterialStore.Scope.databaseRepository("database-b", "owner/repo").account
    )
    #expect(
      TaskBoardKeyMaterialStore.Scope.databaseGlobal("database-a").account
        != TaskBoardKeyMaterialStore.Scope.databaseRepository("database-a", "owner/repo").account
    )
  }
}
