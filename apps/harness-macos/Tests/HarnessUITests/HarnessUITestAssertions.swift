import XCTest

extension HarnessUITestCase {
  func assertFillsColumn(
    child: XCUIElement,
    in container: XCUIElement,
    expectedHorizontalInset: CGFloat,
    tolerance: CGFloat
  ) {
    let containerFrame = container.frame
    let childFrame = child.frame
    let expectedWidth = containerFrame.width - (expectedHorizontalInset * 2)
    XCTAssertEqual(childFrame.width, expectedWidth, accuracy: tolerance * 2)
    XCTAssertEqual(
      childFrame.minX,
      containerFrame.minX + expectedHorizontalInset,
      accuracy: tolerance
    )
    XCTAssertEqual(
      childFrame.maxX,
      containerFrame.maxX - expectedHorizontalInset,
      accuracy: tolerance
    )
  }

  func assertSameRow(_ elements: [XCUIElement], tolerance: CGFloat) {
    guard let first = elements.first else {
      XCTFail("No elements provided")
      return
    }
    let firstFrame = first.frame

    for element in elements.dropFirst() {
      XCTAssertEqual(element.frame.minY, firstFrame.minY, accuracy: tolerance)
    }
  }

  func assertEqualHeights(_ elements: [XCUIElement], tolerance: CGFloat) {
    guard let first = elements.first else {
      XCTFail("No elements provided")
      return
    }
    let firstFrame = first.frame

    for element in elements.dropFirst() {
      XCTAssertEqual(element.frame.height, firstFrame.height, accuracy: tolerance)
    }
  }
}
