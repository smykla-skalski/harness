@preconcurrency import ActivityKit
import Foundation
import HarnessMonitorCore

@MainActor
protocol MobileCommandLiveActivityCoordinating: Sendable {
  func reconcile(
    snapshot: MobileMirrorSnapshot,
    preferredStationID: String?,
    now: Date
  ) async
}

extension MobileCommandLiveActivityCoordinating {
  func reconcile(
    snapshot: MobileMirrorSnapshot,
    preferredStationID: String?
  ) async {
    await reconcile(snapshot: snapshot, preferredStationID: preferredStationID, now: .now)
  }
}

@MainActor
final class LiveMobileCommandLiveActivityCoordinator: MobileCommandLiveActivityCoordinating {
  func reconcile(
    snapshot: MobileMirrorSnapshot,
    preferredStationID: String?,
    now: Date
  ) async {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      await endAllActivities()
      return
    }
    guard
      let presentation = MobileCommandLiveActivityPresentation.activeCommand(
        in: snapshot,
        preferredStationID: preferredStationID,
        now: now
      )
    else {
      await endAllActivities()
      return
    }

    await endActivities(except: presentation.commandID)
    let content = activityContent(for: presentation)
    if let activity = Self.activity(for: presentation.commandID) {
      await activity.update(content)
      return
    }

    do {
      _ = try Activity.request(
        attributes: MobileCommandActivityAttributes(presentation: presentation),
        content: content,
        pushType: nil
      )
    } catch {
      return
    }
  }

  private static func activity(
    for commandID: String
  ) -> Activity<MobileCommandActivityAttributes>? {
    Activity<MobileCommandActivityAttributes>.activities.first {
      $0.attributes.commandID == commandID
    }
  }

  private func activityContent(
    for presentation: MobileCommandLiveActivityPresentation
  ) -> ActivityContent<MobileCommandActivityAttributes.ContentState> {
    ActivityContent(
      state: MobileCommandActivityAttributes.ContentState(presentation: presentation),
      staleDate: presentation.staleDate
    )
  }

  private func endActivities(except commandID: String) async {
    for activity in Activity<MobileCommandActivityAttributes>.activities
    where activity.attributes.commandID != commandID {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
  }

  private func endAllActivities() async {
    for activity in Activity<MobileCommandActivityAttributes>.activities {
      await activity.end(nil, dismissalPolicy: .immediate)
    }
  }
}
