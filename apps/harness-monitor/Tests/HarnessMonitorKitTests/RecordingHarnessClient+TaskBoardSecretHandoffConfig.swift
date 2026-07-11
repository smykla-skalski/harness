@testable import HarnessMonitorKit

struct RecordingTaskBoardSecretHandoffStub {
  var prepareValue = TaskBoardGitRuntimeSecretHandoffPrepareResponse(
    prepared: false,
    runtime: TaskBoardGitRuntimeConfig()
  )
  var prepareError: (any Error)?
  var ackValue = TaskBoardGitRuntimeSecretHandoffAckResponse(acknowledged: true)
  var ackError: (any Error)?
}

extension RecordingHarnessClient {
  var taskBoardSecretHandoffPrepareValue: TaskBoardGitRuntimeSecretHandoffPrepareResponse {
    get { lock.withLock { taskBoardSecretHandoffStub.prepareValue } }
    set { lock.withLock { taskBoardSecretHandoffStub.prepareValue = newValue } }
  }

  var taskBoardSecretHandoffPrepareError: (any Error)? {
    lock.withLock { taskBoardSecretHandoffStub.prepareError }
  }

  var taskBoardSecretHandoffAckValue: TaskBoardGitRuntimeSecretHandoffAckResponse {
    lock.withLock { taskBoardSecretHandoffStub.ackValue }
  }

  var taskBoardSecretHandoffAckError: (any Error)? {
    lock.withLock { taskBoardSecretHandoffStub.ackError }
  }

  func configureTaskBoardSecretHandoffPrepareError(_ error: (any Error)?) {
    lock.withLock { taskBoardSecretHandoffStub.prepareError = error }
  }

  func configureTaskBoardSecretHandoffAckError(_ error: (any Error)?) {
    lock.withLock { taskBoardSecretHandoffStub.ackError = error }
  }
}
