import HarnessMonitorKit

protocol PolicyCanvasAutomationTitledValue {
  var title: String { get }
}

extension AutomationClipboardContentKind: PolicyCanvasAutomationTitledValue {}
extension AutomationPolicyPreprocessor: PolicyCanvasAutomationTitledValue {}
extension AutomationPolicyAction: PolicyCanvasAutomationTitledValue {}
extension AutomationPolicyPostprocessor: PolicyCanvasAutomationTitledValue {}

extension AutomationPolicyOCRConfiguration.RecognitionLevel: PolicyCanvasAutomationTitledValue {
  var title: String {
    switch self {
    case .accurate: "Accurate"
    case .fast: "Fast"
    }
  }
}

extension ReviewPullRequestExtractionConfiguration.RepositoryMode:
  PolicyCanvasAutomationTitledValue
{
  var title: String {
    switch self {
    case .allConfiguredRepos: "All configured repos"
    case .policyRepositories: "Policy repositories"
    case .activeReviewsRepository: "Active Reviews repo"
    }
  }
}

extension ReviewPullRequestExtractionConfiguration.ResultScope:
  PolicyCanvasAutomationTitledValue
{
  var title: String {
    switch self {
    case .all: "All"
    case .failing: "Failing"
    }
  }
}

extension ReviewPullRequestExtractionConfiguration.FailureSignalMode:
  PolicyCanvasAutomationTitledValue
{
  var title: String {
    switch self {
    case .liveReviews: "Live Reviews"
    case .visualScreenshot: "Visual screenshot"
    case .liveOrVisual: "Live or visual"
    }
  }
}

extension ReviewPullRequestExtractionConfiguration.OutputFormat:
  PolicyCanvasAutomationTitledValue
{
  var title: String {
    switch self {
    case .newlineGitHubURLs: "GitHub URLs"
    case .ownerRepoNumber: "owner/repo#number"
    case .markdownLinks: "Markdown links"
    }
  }
}
