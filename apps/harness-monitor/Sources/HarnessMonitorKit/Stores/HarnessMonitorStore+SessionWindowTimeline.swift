import Foundation

extension HarnessMonitorStore {
  public func loadSessionWindowTimeline(
    sessionID: String,
    snapshot: HarnessMonitorSessionWindowSnapshot,
    request: TimelineWindowRequest,
    retainedLimit: Int? = nil
  ) async -> HarnessMonitorSessionWindowSnapshot? {
    guard connectionState == .online, let client else {
      return nil
    }

    do {
      let response = try await Self.measureOperation {
        try await client.timelineWindow(sessionID: sessionID, request: request)
      }
      recordRequestSuccess()
      let resolved = await timelineWindowWorker.resolveSessionWindow(
        existingTimeline: snapshot.timeline,
        currentWindow: snapshot.timelineWindow,
        response: response.value,
        request: request,
        retainedLimit: retainedLimit
      )
      let nextTranscript =
        if let detail = snapshot.detail,
          snapshot.transcriptSource == .derived
        {
          await sessionWindowPresentationWorker.derivedTranscriptEntries(
            detail: detail,
            timeline: resolved.timeline
          )
        } else {
          snapshot.transcript
        }
      let nextSnapshot = HarnessMonitorSessionWindowSnapshot(
        summary: snapshot.summary,
        detail: snapshot.detail,
        acpAgents: snapshot.acpAgents,
        acpInspectSample: snapshot.acpInspectSample,
        timeline: resolved.timeline,
        transcript: nextTranscript,
        transcriptSource: snapshot.transcriptSource,
        timelineWindow: resolved.timelineWindow,
        source: .live
      )
      if let detail = snapshot.detail {
        scheduleSessionDetailCacheWrite(
          detail,
          timeline: resolved.timeline,
          transcript: nextSnapshot.transcript,
          transcriptSource: nextSnapshot.transcriptSource,
          timelineWindow: resolved.timelineWindow
        )
      }
      return nextSnapshot
    } catch is CancellationError {
      return nil
    } catch {
      let detail = error.localizedDescription
      HarnessMonitorLogger.store.warning(
        """
        session window timeline load failed for \
        \(sessionID, privacy: .public): \(detail, privacy: .public)
        """
      )
      return nil
    }
  }
}
