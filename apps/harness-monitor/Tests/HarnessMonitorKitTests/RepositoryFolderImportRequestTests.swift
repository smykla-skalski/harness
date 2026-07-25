import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Repository folder import request")
struct RepositoryFolderImportRequestTests {
  @Test("Beginning an import presents the picker for that repository")
  func beginningAnImportPresentsThePickerForThatRepository() {
    var request = RepositoryFolderImportRequest()
    #expect(!request.isPresented)

    request.begin(repository: "smykla-skalski/harness")

    #expect(request.isPresented)
  }

  @Test("Dismissal keeps the pending repository for the completion handler")
  func dismissalKeepsThePendingRepositoryForTheCompletionHandler() {
    var request = RepositoryFolderImportRequest()
    request.begin(repository: "smykla-skalski/harness")

    // fileImporter clears isPresented before it calls onCompletion.
    request.isPresented = false

    #expect(request.consume() == "smykla-skalski/harness")
  }

  @Test("Consuming the request clears it so a later completion cannot reuse it")
  func consumingTheRequestClearsIt() {
    var request = RepositoryFolderImportRequest()
    request.begin(repository: "smykla-skalski/harness")

    #expect(request.consume() == "smykla-skalski/harness")
    #expect(request.consume() == nil)
    #expect(!request.isPresented)
  }

  @Test("Beginning a second import replaces the pending repository")
  func beginningASecondImportReplacesThePendingRepository() {
    var request = RepositoryFolderImportRequest()
    request.begin(repository: "smykla-skalski/harness")
    request.isPresented = false

    request.begin(repository: "kumahq/kuma")

    #expect(request.consume() == "kumahq/kuma")
  }

  @Test("Consuming without a pending request yields nothing")
  func consumingWithoutAPendingRequestYieldsNothing() {
    var request = RepositoryFolderImportRequest()

    #expect(request.consume() == nil)
  }
}
