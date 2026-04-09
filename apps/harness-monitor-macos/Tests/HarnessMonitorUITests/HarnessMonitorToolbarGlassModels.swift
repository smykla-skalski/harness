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
  let sidebar: ToolbarAverageColor
  let detail: ToolbarAverageColor

  static let zero = Self(sidebar: .zero, detail: .zero)

  var debugDescription: String {
    "sidebar[\(sidebar.debugDescription)] detail[\(detail.debugDescription)]"
  }
}
