import AppKit
import Foundation
import HarnessMonitorKit
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

/// Proves where the mark actually lands, by rendering it beside a letter and
/// reading the pixels back.
///
/// A capital `H` is the probe on purpose: no ascender above its cap and no
/// descender below its baseline, so its ink band *is* the cap band. Measuring
/// against a word instead proves nothing, because `Blue` reaches higher than
/// its capital and `Purple` reaches below its baseline, and the ink extent of
/// either centres on nothing a reader perceives.
@MainActor
@Suite("Task board project mark alignment")
struct TaskBoardProjectMarkAlignmentTests {
  /// Renders at 8x so a disagreement smaller than an eighth of a point is still
  /// several pixels, and the tolerance below is not measuring rounding.
  private static let scale: CGFloat = 8
  private static let toleranceInPoints = 0.13

  private struct Surface {
    let name: String
    let font: Font
    let style: NSFont.TextStyle
  }

  private static let surfaces: [Surface] = [
    Surface(name: "card footer", font: .caption, style: .caption1),
    Surface(name: "palette row", font: .callout, style: .callout),
    Surface(name: "settings row", font: .body, style: .body),
  ]

  @Test("The mark centres on the cap band of the text beside it")
  func markCentresOnTheCapBand() throws {
    for surface in Self.surfaces {
      let probe = try #require(Self.render(font: surface.font, style: surface.style))
      let mark = try #require(probe.markBand, "\(surface.name): no mark drawn")
      let cap = try #require(probe.capBand, "\(surface.name): no letter drawn")

      let markCentre = Double(mark.lowerBound + mark.upperBound + 1) / 2
      let capCentre = Double(cap.lowerBound + cap.upperBound + 1) / 2
      let deltaInPoints = (markCentre - capCentre) / Double(Self.scale)

      #expect(
        abs(deltaInPoints) <= Self.toleranceInPoints,
        """
        \(surface.name): mark centre \(markCentre) vs cap centre \(capCentre), \
        off by \(deltaInPoints)pt (mark rows \(mark), cap rows \(cap))
        """
      )
    }
  }

  /// The probe is only worth trusting if it can see a mark that is wrong, so
  /// push one off by a known amount and confirm the measurement reports it.
  @Test("The probe detects a mark that is off")
  func probeDetectsAMarkThatIsOff() throws {
    let offsetInPoints = 2.0
    let probe = try #require(
      Self.render(font: .body, style: .body, extraOffset: offsetInPoints)
    )
    let mark = try #require(probe.markBand)
    let cap = try #require(probe.capBand)

    let markCentre = Double(mark.lowerBound + mark.upperBound + 1) / 2
    let capCentre = Double(cap.lowerBound + cap.upperBound + 1) / 2
    let measured = (markCentre - capCentre) / Double(Self.scale)

    #expect(
      abs(measured - offsetInPoints) < 0.2,
      "the probe read \(measured)pt for a mark pushed \(offsetInPoints)pt down"
    )
  }

  private struct Probe {
    let markBand: ClosedRange<Int>?
    let capBand: ClosedRange<Int>?
  }

  private struct ProbeSheet: View {
    let font: Font
    let style: NSFont.TextStyle
    let extraOffset: CGFloat

    var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        TaskBoardProjectMark(
          style: TaskBoardProjectMarkStyle(color: .red, shape: .square),
          alignsWith: style
        )
        .offset(y: extraOffset)
        Text(verbatim: "H")
          .font(font)
          .foregroundStyle(.black)
      }
      .padding(10)
      .background(.white)
    }
  }

  private static func render(
    font: Font,
    style: NSFont.TextStyle,
    extraOffset: CGFloat = 0
  ) -> Probe? {
    let renderer = ImageRenderer(
      content: ProbeSheet(font: font, style: style, extraOffset: extraOffset)
        .environment(\.colorScheme, .light)
    )
    renderer.scale = scale
    guard let image = renderer.nsImage,
      let data = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: data)
    else {
      return nil
    }
    return Probe(
      markBand: band(in: bitmap) { $0.isChromatic },
      capBand: band(in: bitmap) { $0.isNeutralInk }
    )
  }

  private struct Pixel {
    let red: Double
    let green: Double
    let blue: Double

    /// The mark is the only saturated thing on the sheet.
    var isChromatic: Bool { max(red, green, blue) - min(red, green, blue) > 0.25 }
    /// The letter is the only dark grey thing on it.
    var isNeutralInk: Bool {
      max(red, green, blue) < 0.55 && max(red, green, blue) - min(red, green, blue) <= 0.25
    }
  }

  private static func band(
    in bitmap: NSBitmapImageRep,
    where matches: (Pixel) -> Bool
  ) -> ClosedRange<Int>? {
    var lowest: Int?
    var highest: Int?
    for y in 0..<bitmap.pixelsHigh {
      var found = false
      for x in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y) else { continue }
        let pixel = Pixel(
          red: Double(color.redComponent),
          green: Double(color.greenComponent),
          blue: Double(color.blueComponent)
        )
        if matches(pixel) {
          found = true
          break
        }
      }
      if found {
        lowest = lowest ?? y
        highest = y
      }
    }
    guard let lowest, let highest else {
      return nil
    }
    return lowest...highest
  }
}
