import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("NewSessionViewModel error mapping")
struct NewSessionViewModelErrorMappingTests {
  @Test("server response with worktree message maps to worktreeCreateFailed")
  func serverResponseWithWorktreeMessageMapsToWorktreeCreateFailed() async {
    let apiError = HarnessMonitorAPIError.server(
      code: 400,
      message: "create session worktree: worktree create failed: path exists"
    )
    let spyClient = SpyHarnessClient(error: apiError)
    let viewModel = makeNewSessionViewModel(
      client: spyClient,
      bookmarkResolver: stubBookmarkResolver(id: "B-x", path: "/tmp/x")
    )
    viewModel.title = "Test"
    viewModel.selectedBookmarkId = "B-x"

    let result = await viewModel.submit()

    guard case .failure(.worktreeCreateFailed(let reason)) = result else {
      Issue.record("Expected worktreeCreateFailed, got \(result)")
      return
    }
    #expect(reason.contains("create session worktree"))
  }

  @Test("400 response with no HEAD maps to invalidProject")
  func http400WithNoHeadMapsToInvalidProject() async {
    let apiError = HarnessMonitorAPIError.server(
      code: 400,
      message: "create session worktree: worktree create failed: no HEAD"
    )
    let spyClient = SpyHarnessClient(error: apiError)
    let viewModel = makeNewSessionViewModel(
      client: spyClient,
      bookmarkResolver: stubBookmarkResolver(id: "B-x", path: "/tmp/x")
    )
    viewModel.title = "Test"
    viewModel.selectedBookmarkId = "B-x"

    let result = await viewModel.submit()

    guard case .failure(.invalidProject(let reason)) = result else {
      Issue.record("Expected invalidProject, got \(result)")
      return
    }
    #expect(reason.contains("no HEAD"))
    #expect(viewModel.lastError == NewSessionViewModel.SubmitError.invalidProject(reason: reason))
  }

  @Test("websocket no HEAD maps to invalidProject")
  func websocketNoHeadMapsToInvalidProject() async {
    let transportError = WebSocketTransportError.serverError(
      code: "WORKFLOW_IO",
      message: "create session worktree: worktree create failed: no HEAD"
    )
    let spyClient = SpyHarnessClient(error: transportError)
    let viewModel = makeNewSessionViewModel(
      client: spyClient,
      bookmarkResolver: stubBookmarkResolver(id: "B-x", path: "/tmp/x")
    )
    viewModel.title = "Test"
    viewModel.selectedBookmarkId = "B-x"

    let result = await viewModel.submit()

    guard case .failure(.invalidProject(let reason)) = result else {
      Issue.record("Expected invalidProject, got \(result)")
      return
    }
    #expect(reason.contains("no HEAD"))
  }

  @Test("websocket invalid reference maps to invalidBaseRef")
  func websocketInvalidReferenceMapsToInvalidBaseRef() async {
    let transportError = WebSocketTransportError.serverError(
      code: "WORKFLOW_IO",
      message:
        "create session worktree: worktree create failed: fatal: invalid reference: origin/main"
    )
    let spyClient = SpyHarnessClient(error: transportError)
    let viewModel = makeNewSessionViewModel(
      client: spyClient,
      bookmarkResolver: stubBookmarkResolver(id: "B-x", path: "/tmp/x")
    )
    viewModel.title = "Test"
    viewModel.selectedBookmarkId = "B-x"
    viewModel.baseRef = "origin/main"

    let result = await viewModel.submit()

    guard case .failure(.invalidBaseRef(let ref, let reason)) = result else {
      Issue.record("Expected invalidBaseRef, got \(result)")
      return
    }
    #expect(ref == "origin/main")
    #expect(reason.contains("invalid reference"))
  }

  @Test("websocket bookmark resolution failure maps to bookmarkRevoked")
  func websocketBookmarkResolutionFailureMapsToBookmarkRevoked() async {
    let transportError = WebSocketTransportError.serverError(
      code: "WORKFLOW_IO",
      message:
        """
        resolve bookmark 'B-x': resolution failed: \
        CFURLCreateByResolvingBookmarkData failed: code=259 description=The file \
        couldn’t be opened because it isn’t in the correct format.
        """
    )
    let spyClient = SpyHarnessClient(error: transportError)
    let viewModel = makeNewSessionViewModel(
      client: spyClient,
      bookmarkResolver: stubBookmarkResolver(id: "B-x", path: "/tmp/x")
    )
    viewModel.title = "Test"
    viewModel.selectedBookmarkId = "B-x"

    let result = await viewModel.submit()

    #expect(result == .failure(.bookmarkRevoked(id: "B-x")))
    #expect(viewModel.lastError == NewSessionViewModel.SubmitError.bookmarkRevoked(id: "B-x"))
  }
}
