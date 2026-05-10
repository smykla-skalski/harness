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

  public func appendSelectedTimelineOlderChunk(limit: Int) async {
    guard limit > 0 else {
      HarnessMonitorTimelineTrace.info("store.append_older_skip reason=limit limit=\(limit)")
      return
    }
    guard selectedTimelineWindowLoadTask == nil else {
      HarnessMonitorTimelineTrace.info(
        "store.append_older_skip reason=window_load_active limit=\(limit)"
      )
      return
    }
    guard timelineWindow?.hasOlder == true else {
      HarnessMonitorTimelineTrace.info(
        """
        store.append_older_skip reason=no_older limit=\(limit) \
        loaded=\(timeline.count) \(HarnessMonitorTimelineTrace.windowSummary(timelineWindow))
        """
      )
      return
    }
    let currentWindowEnd = timelineWindow?.windowEnd ?? timeline.count
    let totalCount = max(currentWindowEnd, timeline.count, timelineWindow?.totalCount ?? 0)
    let targetEnd = min(totalCount, currentWindowEnd + limit)
    HarnessMonitorTimelineTrace.info(
      """
      store.append_older_start limit=\(limit) currentEnd=\(currentWindowEnd) \
      targetEnd=\(targetEnd) total=\(totalCount) loaded=\(timeline.count)
      """
    )
    await loadSelectedTimelinePrefix(targetEnd: targetEnd, pageSize: limit)
  }

  private func loadSelectedTimelinePrefix(targetEnd: Int, pageSize: Int) async {
    guard pageSize > 0 else {
      traceSelectedTimelinePrefixSkipPageSize(targetEnd: targetEnd, pageSize: pageSize)
      return
    }
    guard let sessionID = selectedSessionID, let selectedSession, connectionState == .online,
      let client
    else {
      traceSelectedTimelinePrefixUnavailable()
      return
    }

    let currentWindowEnd = timelineWindow?.windowEnd ?? timeline.count
    let clampedTargetEnd = min(
      max(targetEnd, 0),
      max(currentWindowEnd, timeline.count, timelineWindow?.totalCount ?? 0)
    )
    guard clampedTargetEnd > 0, currentWindowEnd < clampedTargetEnd else {
      traceSelectedTimelinePrefixTargetNotAhead(
        targetEnd: targetEnd,
        clampedTargetEnd: clampedTargetEnd,
        currentWindowEnd: currentWindowEnd
      )
      return
    }

    let currentRevision = timelineWindow?.revision
    let missingCount = clampedTargetEnd - currentWindowEnd
    let loadKey = SelectedTimelinePageLoadKey(
      sessionID: sessionID,
      targetEnd: clampedTargetEnd,
      pageSize: pageSize,
      revision: currentRevision
    )

    if let selectedTimelinePageLoadTask, selectedTimelinePageLoadKey == loadKey {
      traceSelectedTimelinePrefixJoinExisting(
        sessionID: sessionID,
        targetEnd: clampedTargetEnd,
        pageSize: pageSize,
        revision: currentRevision
      )
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
    traceSelectedTimelinePrefixTaskStart(
      sessionID: sessionID,
      targetEnd: clampedTargetEnd,
      missingCount: missingCount,
      pageSize: pageSize,
      revision: currentRevision
    )
    let task = selectedTimelinePrefixTask(
      context: SelectedTimelinePrefixTaskContext(
        token: token,
        sessionID: sessionID,
        selectedSession: selectedSession,
        client: client,
        targetEnd: clampedTargetEnd,
        missingCount: missingCount,
        currentRevision: currentRevision,
        loadKey: loadKey
      )
    )
    selectedTimelinePageLoadTask = task
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
          currentRevision: context.currentRevision
        )
        HarnessMonitorTimelineTrace.info(
          "store.prefix_response session=\(context.sessionID) "
            + HarnessMonitorTimelineTrace.windowSummary(response)
        )
        guard !Task.isCancelled else {
          HarnessMonitorTimelineTrace.info(
            "store.prefix_drop reason=cancelled session=\(context.sessionID)"
          )
          return
        }
        guard
          self.isCurrentSelectedTimelinePageLoad(
            context.token,
            key: context.loadKey
          )
        else {
          HarnessMonitorTimelineTrace.info(
            "store.prefix_drop reason=stale session=\(context.sessionID)"
          )
          return
        }
        self.applySelectedTimelinePageResponse(
          response,
          currentRevision: context.currentRevision,
          selectedSession: context.selectedSession
        )
      } catch is CancellationError {
        HarnessMonitorTimelineTrace.info(
          "store.prefix_cancelled session=\(context.sessionID)"
        )
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

  private func traceSelectedTimelinePrefixSkipPageSize(targetEnd: Int, pageSize: Int) {
    HarnessMonitorTimelineTrace.info(
      "store.prefix_skip reason=page_size targetEnd=\(targetEnd) pageSize=\(pageSize)"
    )
  }

  private func traceSelectedTimelinePrefixUnavailable() {
    HarnessMonitorTimelineTrace.info(
      """
      store.prefix_skip reason=unavailable session=\(selectedSessionID ?? "nil") \
      selected=\(selectedSession != nil) state=\(String(describing: connectionState)) \
      client=\(client != nil)
      """
    )
  }

  private func traceSelectedTimelinePrefixTargetNotAhead(
    targetEnd: Int,
    clampedTargetEnd: Int,
    currentWindowEnd: Int
  ) {
    HarnessMonitorTimelineTrace.info(
      """
      store.prefix_skip reason=target_not_ahead targetEnd=\(targetEnd) \
      clampedTargetEnd=\(clampedTargetEnd) currentEnd=\(currentWindowEnd) \
      loaded=\(timeline.count) \(HarnessMonitorTimelineTrace.windowSummary(timelineWindow))
      """
    )
  }

  private func traceSelectedTimelinePrefixJoinExisting(
    sessionID: String,
    targetEnd: Int,
    pageSize: Int,
    revision: Int64?
  ) {
    HarnessMonitorTimelineTrace.info(
      """
      store.prefix_join_existing session=\(sessionID) targetEnd=\(targetEnd) \
      pageSize=\(pageSize) revision=\(revision ?? -1)
      """
    )
  }

  private func traceSelectedTimelinePrefixTaskStart(
    sessionID: String,
    targetEnd: Int,
    missingCount: Int,
    pageSize: Int,
    revision: Int64?
  ) {
    HarnessMonitorTimelineTrace.info(
      """
      store.prefix_task_start session=\(sessionID) targetEnd=\(targetEnd) \
      missing=\(missingCount) pageSize=\(pageSize) revision=\(revision ?? -1)
      """
    )
  }
}

private struct SelectedTimelinePrefixTaskContext {
  let token: UInt64
  let sessionID: String
  let selectedSession: SessionDetail
  let client: any HarnessMonitorClientProtocol
  let targetEnd: Int
  let missingCount: Int
  let currentRevision: Int64?
  let loadKey: HarnessMonitorStore.SelectedTimelinePageLoadKey
}
