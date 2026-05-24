import AppIntents
import HarnessMonitorKit

public enum HarnessMonitorIntentDonations {
  public static func donateApprove(items: [ReviewItem]) {
    Task.detached(priority: .utility) {
      for item in items {
        let intent = ApprovePullRequestIntent()
        intent.pullRequest = PullRequestEntity(from: item)
        await IntentDonationRecorder.shared.recordDonation(
          kind: .pullRequest, id: item.pullRequestID
        )
        _ = try? await IntentDonationManager.shared.donate(intent: intent)
      }
    }
  }

  public static func donateMerge(items: [ReviewItem]) {
    Task.detached(priority: .utility) {
      for item in items {
        let intent = MergePullRequestIntent()
        intent.pullRequest = PullRequestEntity(from: item)
        await IntentDonationRecorder.shared.recordDonation(
          kind: .pullRequest, id: item.pullRequestID
        )
        _ = try? await IntentDonationManager.shared.donate(intent: intent)
      }
    }
  }

  public static func donateRerunChecks(items: [ReviewItem]) {
    Task.detached(priority: .utility) {
      for item in items {
        let intent = RerunChecksIntent()
        intent.pullRequest = PullRequestEntity(from: item)
        await IntentDonationRecorder.shared.recordDonation(
          kind: .pullRequest, id: item.pullRequestID
        )
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
        await IntentDonationRecorder.shared.recordDonation(
          kind: .pullRequest, id: item.pullRequestID
        )
        _ = try? await IntentDonationManager.shared.donate(intent: intent)
      }
    }
  }

  public static func donateDispatch(items: [TaskBoardItem]) {
    Task.detached(priority: .utility) {
      for item in items {
        let intent = DispatchTaskIntent()
        intent.item = TaskBoardItemEntity(from: item)
        await IntentDonationRecorder.shared.recordDonation(
          kind: .taskBoardItem, id: item.id
        )
        _ = try? await IntentDonationManager.shared.donate(intent: intent)
      }
    }
  }

  public static func donateApprovePlan(items: [TaskBoardItem]) {
    Task.detached(priority: .utility) {
      for item in items {
        let intent = ApproveTaskBoardPlanIntent()
        intent.item = TaskBoardItemEntity(from: item)
        await IntentDonationRecorder.shared.recordDonation(
          kind: .taskBoardItem, id: item.id
        )
        _ = try? await IntentDonationManager.shared.donate(intent: intent)
      }
    }
  }

  public static func donateRefreshRepository(_ repositoryID: String) {
    Task.detached(priority: .utility) {
      guard let entity = RepositoryEntity(rawIdentifier: repositoryID) else { return }
      let intent = RefreshRepositoryIntent()
      intent.repository = entity
      await IntentDonationRecorder.shared.recordDonation(
        kind: .repository, id: entity.id
      )
      _ = try? await IntentDonationManager.shared.donate(intent: intent)
    }
  }
}
