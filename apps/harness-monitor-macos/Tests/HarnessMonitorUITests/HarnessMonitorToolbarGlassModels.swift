import Foundation

struct ToolbarGlassMeasurement {
  let initial: ToolbarGlassStats
  let afterClose: ToolbarGlassStats
}

struct ToolbarGlassStats {
  let mean: Double
  let stddev: Double
  let sampleCount: Int

  static let zero = Self(mean: 0, stddev: 0, sampleCount: 0)

  var debugDescription: String {
    String(
      format: "mean=%.4f stddev=%.4f samples=%d",
      mean,
      stddev,
      sampleCount
    )
  }
}

struct ToolbarAverageColor {
  let red: Double
  let green: Double
  let blue: Double

  static let zero = Self(red: 0, green: 0, blue: 0)

  var greenDominance: Double {
    green - max(red, blue)
  }

  func distance(to other: Self) -> Double {
    let deltaRed = red - other.red
    let deltaGreen = green - other.green
    let deltaBlue = blue - other.blue
    return sqrt(
      (deltaRed * deltaRed)
        + (deltaGreen * deltaGreen)
        + (deltaBlue * deltaBlue)
    )
  }

  var debugDescription: String {
    String(
      format: "r=%.4f g=%.4f b=%.4f greenDominance=%.4f",
      red,
      green,
      blue,
      greenDominance
    )
  }
}

struct SplitBoundaryTintMeasurement {
  let sidebarToolbar: ToolbarAverageColor
  let sidebarBelowToolbar: ToolbarAverageColor
  let detailToolbar: ToolbarAverageColor
  let debugContext: String

  static let zero = Self(
    sidebarToolbar: .zero,
    sidebarBelowToolbar: .zero,
    detailToolbar: .zero,
    debugContext: ""
  )

  var sidebarSeamDistance: Double {
    sidebarToolbar.distance(to: sidebarBelowToolbar)
  }

  var debugDescription: String {
    let summary = """
    sidebarToolbar[\(sidebarToolbar.debugDescription)] \
    sidebarBelowToolbar[\(sidebarBelowToolbar.debugDescription)] \
    detailToolbar[\(detailToolbar.debugDescription)] \
    sidebarSeamDistance=\(String(format: "%.4f", sidebarSeamDistance))
    """
    guard !debugContext.isEmpty else {
      return summary
    }
    return "\(summary) \(debugContext)"
  }
}
