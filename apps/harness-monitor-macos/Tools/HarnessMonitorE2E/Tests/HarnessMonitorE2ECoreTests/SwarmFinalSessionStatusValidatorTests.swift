import Foundation
import XCTest

@testable import HarnessMonitorE2ECore

final class SwarmFinalSessionStatusValidatorTests: XCTestCase {
  func testValidateAcceptsKeyedTaskMapWithArbitrationAndObserveTasks() throws {
    let json: [String: Any] = [
      "status": "ended",
      "tasks": [
        "task-1": ["status": "done", "source": "leader"],
        "task-2": ["status": "done", "source": "leader", "arbitration": ["round": 3]],
        "task-3": ["status": "done", "source": "observe"],
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    XCTAssertNoThrow(try SwarmFinalSessionStatusValidator.validate(data))
  }

  func testValidateAcceptsLegacyTaskArrayShape() throws {
    let json: [String: Any] = [
      "status": "ended",
      "tasks": [
        ["status": "done", "source": "leader", "arbitration": ["round": 1]],
        ["status": "done", "source": "observe"],
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    XCTAssertNoThrow(try SwarmFinalSessionStatusValidator.validate(data))
  }

  func testValidateRejectsNonEndedStatus() throws {
    let json: [String: Any] = [
      "status": "running",
      "tasks": ["task-1": ["arbitration": ["round": 1], "source": "observe"]],
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    XCTAssertThrowsError(try SwarmFinalSessionStatusValidator.validate(data)) { error in
      let message = String(describing: error)
      XCTAssertTrue(
        message.contains("not ended"),
        "Validator must surface the non-ended-status reason; got \(message)."
      )
    }
  }

  func testValidateRejectsMissingArbitrationTask() throws {
    let json: [String: Any] = [
      "status": "ended",
      "tasks": [
        "task-1": ["status": "done", "source": "leader"],
        "task-2": ["status": "done", "source": "observe"],
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    XCTAssertThrowsError(try SwarmFinalSessionStatusValidator.validate(data)) { error in
      let message = String(describing: error)
      XCTAssertTrue(
        message.contains("arbitration") || message.contains("observe"),
        "Validator must call out missing expected tasks; got \(message)."
      )
    }
  }

  func testValidateRejectsMissingObserveTask() throws {
    let json: [String: Any] = [
      "status": "ended",
      "tasks": [
        "task-1": ["status": "done", "arbitration": ["round": 2], "source": "leader"]
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    XCTAssertThrowsError(try SwarmFinalSessionStatusValidator.validate(data))
  }

  func testValidateTreatsNullArbitrationAsAbsent() throws {
    let json: [String: Any] = [
      "status": "ended",
      "tasks": [
        "task-1": ["status": "done", "arbitration": NSNull(), "source": "leader"],
        "task-2": ["status": "done", "source": "observe"],
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    XCTAssertThrowsError(try SwarmFinalSessionStatusValidator.validate(data))
  }
}
