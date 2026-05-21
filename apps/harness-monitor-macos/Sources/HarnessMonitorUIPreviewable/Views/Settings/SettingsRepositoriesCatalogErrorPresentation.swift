import Foundation
import HarnessMonitorKit

struct SettingsRepositoriesCatalogErrorPresentation: Equatable {
  enum RecoveryAction: Equatable {
    case openSecrets
    case openURL(URL)

    var title: String {
      switch self {
      case .openSecrets:
        "Open Secrets"
      case .openURL:
        "Open Token Settings"
      }
    }
  }

  let title: String
  let message: String
  let action: RecoveryAction?

  init(title: String, message: String, action: RecoveryAction?) {
    self.title = title
    self.message = message
    self.action = action
  }

  init(error: any Error, organization: String) {
    self = Self.presentation(for: error, organization: organization)
  }

  var actionHint: String {
    switch action {
    case .openSecrets:
      "Open the Secrets settings section."
    case .openURL:
      "Open GitHub token settings in your browser."
    case nil:
      ""
    }
  }

  private static func presentation(
    for error: any Error,
    organization: String
  ) -> Self {
    let rawMessage = sourceMessage(from: error)
    let normalized = rawMessage.lowercased()
    let organizationReference = organization.isEmpty ? "this organization" : organization

    if normalized.contains("requires a github token") {
      return Self(
        title: "GitHub token required",
        message: "Add a GitHub token in Settings > Secrets, then load repositories again.",
        action: .openSecrets
      )
    }

    if normalized.contains("forbids access via a fine-grained personal access") {
      let action = tokenSettingsAction(in: rawMessage)
      if normalized.contains("token's lifetime is greater than 366 days") {
        return Self(
          title: "GitHub token needs attention",
          message:
            "GitHub blocked access to \(organizationReference) because the current "
            + "fine-grained token exceeds the organization's lifetime policy. "
            + "Update the token, then load repositories again.",
          action: action
        )
      }

      return Self(
        title: "GitHub access is blocked",
        message:
          "GitHub blocked access to \(organizationReference) for the current fine-grained "
          + "token. Update the token's organization access, then load repositories again.",
        action: action
      )
    }

    if normalized.contains("was not found or is not accessible")
      || normalized.contains("could not resolve to an organization")
    {
      return Self(
        title: "Organization unavailable",
        message:
          "GitHub couldn't load repositories for \(organizationReference). Check the "
          + "organization name and confirm the current token can access it, then try again.",
        action: nil
      )
    }

    if normalized.contains("rate limit") {
      return Self(
        title: "GitHub is rate limiting requests",
        message: "Wait a moment, then load repositories again.",
        action: nil
      )
    }

    if normalized.contains("bad credentials") || normalized.contains("unauthorized") {
      return Self(
        title: "GitHub token was rejected",
        message: "Update the GitHub token in Settings > Secrets, then load repositories again.",
        action: .openSecrets
      )
    }

    return Self(
      title: "Couldn't load repositories",
      message:
        "GitHub couldn't load repositories for \(organizationReference). Check the "
        + "organization name and your GitHub access, then try again.",
      action: nil
    )
  }

  private static func sourceMessage(from error: any Error) -> String {
    if let apiError = error as? HarnessMonitorAPIError {
      return apiError.serverMessage ?? apiError.errorDescription ?? error.localizedDescription
    }
    return error.localizedDescription
  }

  private static func tokenSettingsAction(in message: String) -> RecoveryAction? {
    guard
      let range = message.range(
        of: #"https://github\.com/settings/personal-access-tokens/[^\s)]+"#,
        options: .regularExpression
      )
    else {
      return nil
    }
    let urlString = String(message[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".)"))
    guard let url = URL(string: urlString) else {
      return nil
    }
    return .openURL(url)
  }
}
