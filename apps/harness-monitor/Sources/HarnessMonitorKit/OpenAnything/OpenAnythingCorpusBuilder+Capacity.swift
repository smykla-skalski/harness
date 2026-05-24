extension OpenAnythingCorpusBuilder {
  static func estimatedRecordCount(
    input: OpenAnythingCorpusInput,
    actionCount: Int,
    windowCount: Int,
    pluginRecordCount: Int
  ) -> Int {
    let loadedSessionCount =
      input.loadedSession.map { snapshot in
        snapshot.agents.count
          + snapshot.tasks.count
          + min(snapshot.timeline.count, 200)
      } ?? 0
    return actionCount
      + windowCount
      + input.settingsSections.count
      + input.sessions.count
      + input.taskBoardItems.count
      + input.decisions.count
      + input.reviews.count
      + loadedSessionCount
      + pluginRecordCount
  }
}
