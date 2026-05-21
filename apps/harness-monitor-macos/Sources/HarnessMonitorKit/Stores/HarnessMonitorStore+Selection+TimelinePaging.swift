import Foundation

extension HarnessMonitorStore {
  public func loadSelectedTimelinePage(page: Int, pageSize: Int) async {
    guard pageSize > 0 else {
      return
    }
    let totalCount = max(timeline.count, timelineWindow?.totalCount ?? 0)
    let pageCount = max(1, Int(ceil(Double(totalCount) / Double(pageSize))))
    let clampedPage = min(max(page, 0), pageCount - 1)
    let targetEnd = min(totalCount, (clampedPage + 1) * pageSize)
    await loadSelectedTimelinePrefix(targetEnd: targetEnd, pageSize: pageSize)
  }

  public func appendSelectedTimelineOlderChunk(limit: Int, retainedLimit: Int? = nil) async {
    guard limit > 0 else {
      return
    }
    guard selectedTimelineLoad.windowLoadTask == nil else {
      return
    }
    guard timelineWindow?.hasOlder == true else {
      return
    }
    let currentWindowEnd = timelineWindow?.windowEnd ?? timeline.count
    let totalCount = max(currentWindowEnd, timeline.count, timelineWindow?.totalCount ?? 0)
    let targetEnd = min(totalCount, currentWindowEnd + limit)
    await loadSelectedTimelinePrefix(
      targetEnd: targetEnd,
      pageSize: limit,
      retainedLimit: retainedLimit
    )
  }

  private func loadSelectedTimelinePrefix(
    targetEnd: Int,
    pageSize: Int,
    retainedLimit: Int? = nil
  ) async {
    guard pageSize > 0 else {
      return
    }
    guard let sessionID = selectedSessionID, let selectedSession, connectionState == .online,
      let client
    else {
      return
    }

    let currentWindowEnd = timelineWindow?.windowEnd ?? timeline.count
    let clampedTargetEnd = min(
      max(targetEnd, 0),
      max(currentWindowEnd, timeline.count, timelineWindow?.totalCount ?? 0)
    )
    guard clampedTargetEnd > 0, currentWindowEnd < clampedTargetEnd else {
      return
    }

    let currentRevision = timelineWindow?.revision
    let missingCount = clampedTargetEnd - currentWindowEnd
    let loadKey = SelectedTimelinePageLoadKey(
      sessionID: sessionID,
      targetEnd: clampedTargetEnd,
      pageSize: pageSize,
      retainedLimit: retainedLimit,
      revision: currentRevision
    )

    if let selectedTimelineLoad.pageLoadTask, selectedTimelineLoad.pageLoadKey == loadKey {
      await selectedTimelineLoad.pageLoadTask.value
      return
    }

    cancelSelectedTimelinePageLoad()
    selectedTimelineLoad.pageLoadSequence &+= 1
    let token = selectedTimelineLoad.pageLoadSequence
    selectedTimelineLoad.pageLoadKey = loadKey

    withUISyncBatch {
      isTimelineLoading = true
    }
    let task = selectedTimelinePrefixTask(
      context: SelectedTimelinePrefixTaskContext(
        token: token,
        sessionID: sessionID,
        selectedSession: selectedSession,
        client: client,
        targetEnd: clampedTargetEnd,
        missingCount: missingCount,
        retainedLimit: retainedLimit,
        currentRevision: currentRevision,
        loadKey: loadKey
      )
    )
    selectedTimelineLoad.pageLoadTask = task
    await task.value
  }

  private func selectedTimelinePrefixTask(
    context: SelectedTimelinePrefixTaskContext
  ) -> Task<Void, Never> {
    Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      defer {
        self.finishSelectedTimelinePageLoadIfCurrent(
          context.token,
          sessionID: context.sessionID
        )
      }

      do {
        let response = try await self.fetchSelectedTimelinePrefix(
          using: context.client,
          sessionID: context.sessionID,
          targetEnd: context.targetEnd,
          missingCount: context.missingCount,
          retainedLimit: context.retainedLimit,
          currentRevision: context.currentRevision
        )
        guard !Task.isCancelled else {
          return
        }
        guard
          self.isCurrentSelectedTimelinePageLoad(
            context.token,
            key: context.loadKey
          )
        else {
          return
        }
        await self.applySelectedTimelinePageResponse(
          response,
          currentRevision: context.currentRevision,
          retainedLimit: context.retainedLimit,
          selectedSession: context.selectedSession
        )
      } catch is CancellationError {
        return
      } catch {
        guard
          self.isCurrentSelectedTimelinePageLoad(
            context.token,
            key: context.loadKey
          )
        else {
          return
        }
        let detail = error.localizedDescription
        HarnessMonitorLogger.store.warning(
          """
          timeline page load failed for \
          \(context.sessionID, privacy: .public): \(detail, privacy: .public)
          """
        )
      }
    }
  }
}

private struct SelectedTimelinePrefixTaskContext {
  let token: UInt64
  let sessionID: String
  let selectedSession: SessionDetail
  let client: any HarnessMonitorClientProtocol
  let targetEnd: Int
  let missingCount: Int
  let retainedLimit: Int?
  let currentRevision: Int64?
  let loadKey: HarnessMonitorStore.SelectedTimelinePageLoadKey
}
