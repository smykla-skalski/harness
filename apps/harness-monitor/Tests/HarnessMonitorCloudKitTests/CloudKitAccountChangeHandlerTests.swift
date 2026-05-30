import Foundation
@testable import HarnessMonitorCloudKit
import XCTest

final class CloudKitAccountChangeHandlerTests: XCTestCase {
  func testHandleFiresInvalidateThenRegister() async {
    let recorder = SyncRecorder()
    let handler = CloudKitAccountChangeHandler(
      invalidate: { recorder.record("invalidate") },
      register: { recorder.record("register") }
    )

    await handler.handle()

    XCTAssertEqual(recorder.calls, ["invalidate", "register"])
  }

  func testHandleFiresInvalidateRegisterThenOnChange() async {
    let recorder = SyncRecorder()
    let handler = CloudKitAccountChangeHandler(
      invalidate: { recorder.record("invalidate") },
      register: { recorder.record("register") },
      onChange: { recorder.record("onChange") }
    )

    await handler.handle()

    XCTAssertEqual(recorder.calls, ["invalidate", "register", "onChange"])
  }

  func testHandleInvokesOnChangeOnEachCall() async {
    let recorder = SyncRecorder()
    let handler = CloudKitAccountChangeHandler(
      invalidate: { recorder.record("invalidate") },
      register: { recorder.record("register") },
      onChange: { recorder.record("onChange") }
    )

    await handler.handle()
    await handler.handle()

    XCTAssertEqual(recorder.calls.filter { $0 == "onChange" }.count, 2)
  }

  func testHandleCalledTwiceFiresAllCallbacksTwice() async {
    let recorder = SyncRecorder()
    let handler = CloudKitAccountChangeHandler(
      invalidate: { recorder.record("invalidate") },
      register: { recorder.record("register") }
    )

    async let firstHandle: Void = handler.handle()
    async let secondHandle: Void = handler.handle()
    _ = await (firstHandle, secondHandle)

    let calls = recorder.calls
    XCTAssertEqual(calls.count, 4)
    XCTAssertEqual(calls.filter { $0 == "invalidate" }.count, 2)
    XCTAssertEqual(calls.filter { $0 == "register" }.count, 2)
  }
}

private final class SyncRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []

  func record(_ tag: String) {
    lock.lock()
    defer { lock.unlock() }
    stored.append(tag)
  }

  var calls: [String] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}
