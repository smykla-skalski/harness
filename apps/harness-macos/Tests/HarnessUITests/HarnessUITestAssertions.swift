import XCTest

extension HarnessUITestCase {
  func assertFillsColumn(
    child: XCUIElement,
    in container: XCUIElement,
    expectedHorizontalInset: CGFloat,
    tolerance: CGFloat
  ) {
    let expectedWidth = container.frame.width - (expectedHorizontalInset * 2)
    XCTAssertEqual(child.frame.width, expectedWidth, accuracy: tolerance * 2)
    XCTAssertEqual(
      child.frame.minX,
      container.frame.minX + expectedHorizontalInset,
      accuracy: tolerance
    )
    XCTAssertEqual(
      child.frame.maxX,
      container.frame.maxX - expectedHorizontalInset,
      accuracy: tolerance
    )
  }

  func assertSameRow(_ elements: [XCUIElement], tolerance: CGFloat) {
    guard let first = elements.first else {
      XCTFail("No elements provided")
      return
    }

    for element in elements.dropFirst() {
      XCTAssertEqual(element.frame.minY, first.frame.minY, accuracy: tolerance)
    }
  }

  func assertEqualHeights(_ elements: [XCUIElement], tolerance: CGFloat) {
    guard let first = elements.first else {
      XCTFail("No elements provided")
      return
    }

    for element in elements.dropFirst() {
      XCTAssertEqual(element.frame.height, first.frame.height, accuracy: tolerance)
    }
  }
}
