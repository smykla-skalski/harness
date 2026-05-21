import Foundation
import HarnessMonitorKit

/// User-facing copy for the most common GitHub auth failure that the daemon
/// can report. Kept as a constant so tests can verify the exact text without
/// depending on the daemon error envelope.
let dashboardDepsGitHubAuthFailureMessage = """
  GitHub rejected the configured token (HTTP 401 Bad credentials). The token \
  may have expired or been revoked. Update it in Settings > Secrets and try again
  """

let dashboardDepsDecodingFailureMessage = """
  Harness Monitor could not read the daemon's dependency response. The daemon \
  and app may be on different versions - restart the daemon, then retry
  """

/// Maps an error thrown from the daemon dependency-updates path into a
/// user-facing string. `error.localizedDescription` is unhelpful for
/// `DecodingError` and bare transport messages, so the helper pattern-matches
/// the known cases and surfaces actionable copy. Unknown errors fall through to
/// the underlying localized description.
func dashboardDependenciesErrorMessage(for error: any Error) -> String {
  if let apiError = error as? HarnessMonitorAPIError,
    let description = apiError.errorDescription
  {
    return description
  }

  if error is DecodingError {
    return dashboardDepsDecodingFailureMessage
  }

  let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  if description.contains("GitHub API returned 401") {
    return dashboardDepsGitHubAuthFailureMessage
  }
  return description
}
