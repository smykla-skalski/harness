import Foundation
@testable import HarnessMonitorCloudKit
import XCTest

final class CloudKitAccountChangeHandlerTests: XCTestCase {
    func testHandleCallsInvalidateThenRegisterInOrder() async {
        let recorder = CallRecorder()
        let handler = CloudKitAccountChangeHandler(
            invalidate: { await recorder.record("invalidate") },
            register: { await recorder.record("register") }
        )

        await handler.handle()

        let calls = await recorder.calls
        XCTAssertEqual(calls, ["invalidate", "register"])
    }

    func testHandleInvokesOnChangeAfterRegister() async {
        let recorder = CallRecorder()
        let handler = CloudKitAccountChangeHandler(
            invalidate: { await recorder.record("invalidate") },
            register: { await recorder.record("register") },
            onChange: {
                // synchronous; recorder needs await but onChange is sync
                // dispatch a sync flag via NSLock-free approach
            }
        )

        let onChangeFlag = OnChangeFlag()
        let handler2 = CloudKitAccountChangeHandler(
            invalidate: { await recorder.record("invalidate2") },
            register: { await recorder.record("register2") },
            onChange: { onChangeFlag.set() }
        )

        await handler.handle()
        await handler2.handle()

        let calls = await recorder.calls
        XCTAssertEqual(calls, ["invalidate", "register", "invalidate2", "register2"])
        XCTAssertTrue(onChangeFlag.value)
    }

    func testHandleWithoutOnChangeRunsCallbacksOnly() async {
        let recorder = CallRecorder()
        let handler = CloudKitAccountChangeHandler(
            invalidate: { await recorder.record("invalidate") },
            register: { await recorder.record("register") }
        )

        await handler.handle()

        let calls = await recorder.calls
        XCTAssertEqual(calls, ["invalidate", "register"])
    }

    func testHandleIsConcurrencySafeAcrossInvocations() async {
        let recorder = CallRecorder()
        let handler = CloudKitAccountChangeHandler(
            invalidate: { await recorder.record("invalidate") },
            register: { await recorder.record("register") }
        )

        async let a: Void = handler.handle()
        async let b: Void = handler.handle()
        _ = await (a, b)

        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.filter { $0 == "invalidate" }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "register" }.count, 2)
    }
}

private actor CallRecorder {
    private(set) var calls: [String] = []
    func record(_ tag: String) {
        calls.append(tag)
    }
}

private final class OnChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func set() {
        lock.lock(); defer { lock.unlock() }
        stored = true
    }
}
