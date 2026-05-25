extension HarnessMonitorClientProtocol {
  public func githubStatus() async throws -> GitHubApiDiagnostics {
    try await diagnostics().githubApi ?? .empty
  }
}
