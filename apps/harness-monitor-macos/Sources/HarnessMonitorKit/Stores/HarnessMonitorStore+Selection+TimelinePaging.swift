import Foundation

extension HarnessMonitorStore {
  public func loadSelectedTimelinePage(page: Int, pageSize: Int) async {
    guard pageSize > 0 else {
      return
    }
    guard let sessionID = selectedSessionID, let selectedSession, connectionState == .online,
      let client
    else {
      return
    }

    let totalCount = max(timeline.count, timelineWindow?.totalCount ?? 0)
    let pageCount = max(1, Int(ceil(Double(totalCount) / Double(pageSize))))
    let clampedPage = min(max(page, 0), pageCount - 1)
    let targetEnd = min(totalCount, (clampedPage + 1) * pageSize)

    guard targetEnd > 0, timeline.count < targetEnd else {
      return
    }

    let currentRevision = timelineWindow?.revision
    let missingCount = targetEnd - timeline.count
    let loadKey = SelectedTimelinePageLoadKey(
      sessionID: sessionID,
      targetEnd: targetEnd,
      pageSize: pageSize,
      revision: currentRevision
    )

    if let selectedTimelinePageLoadTask, selectedTimelinePageLoadKey == loadKey {
      await selectedTimelinePageLoadTask.value
      return
    }

    cancelSelectedTimelinePageLoad()
    selectedTimelinePageLoadSequence &+= 1
    let token = selectedTimelinePageLoadSequence
    selectedTimelinePageLoadKey = loadKey

    withUISyncBatch {
      isTimelineLoading = true
    }
    let task = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      defer {
        self.finishSelectedTimelinePageLoadIfCurrent(token, sessionID: sessionID)
      }

      do {
        let response = try await self.fetchSelectedTimelinePrefix(
          using: client,
          sessionID: sessionID,
          targetEnd: targetEnd,
          missingCount: missingCount,
          currentRevision: currentRevision
        )
        guard !Task.isCancelled else {
          return
        }
        guard self.isCurrentSelectedTimelinePageLoad(token, key: loadKey) else {
          return
        }
        self.applySelectedTimelinePageResponse(
          response,
          currentRevision: currentRevision,
          selectedSession: selectedSession
        )
      } catch is CancellationError {
        return
      } catch {
        guard self.isCurrentSelectedTimelinePageLoad(token, key: loadKey) else {
          return
        }
        let detail = error.localizedDescription
        HarnessMonitorLogger.store.warning(
          "timeline page load failed for \(sessionID, privacy: .public): \(detail, privacy: .public)"
        )
      }
    }
    selectedTimelinePageLoadTask = task
    await task.value
  }
}
