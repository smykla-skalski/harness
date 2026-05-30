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
}
