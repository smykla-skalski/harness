import AppIntents
import HarnessMonitorKit

public enum HarnessMonitorIntentDonations {
  public static func donateApprove(items: [ReviewItem]) {
    Task.detached(priority: .utility) {
      for item in items {
        let intent = ApprovePullRequestIntent()
        intent.pullRequest = PullRequestEntity(from: item)
        _ = try? await IntentDonationManager.shared.donate(intent: intent)
      }
    }
  }

  public static func donateMerge(items: [ReviewItem]) {
    Task.detached(priority: .utility) {
      for item in items {
        let intent = MergePullRequestIntent()
        intent.pullRequest = PullRequestEntity(from: item)
        _ = try? await IntentDonationManager.shared.donate(intent: intent)
      }
    }
  }

  public static func donateRerunChecks(items: [ReviewItem]) {
    Task.detached(priority: .utility) {
      for item in items {
        let intent = RerunChecksIntent()
        intent.pullRequest = PullRequestEntity(from: item)
        _ = try? await IntentDonationManager.shared.donate(intent: intent)
      }
    }
  }

  public static func donateAddLabel(_ label: String, to items: [ReviewItem]) {
    Task.detached(priority: .utility) {
      for item in items {
        let intent = AddLabelToPullRequestIntent()
        intent.pullRequest = PullRequestEntity(from: item)
        intent.label = label
        _ = try? await IntentDonationManager.shared.donate(intent: intent)
      }
    }
  }
}
