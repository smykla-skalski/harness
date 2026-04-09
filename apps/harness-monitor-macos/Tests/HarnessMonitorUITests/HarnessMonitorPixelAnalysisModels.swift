struct RGBColor {
  let red: Double
  let green: Double
  let blue: Double

  static let zero = Self(red: 0, green: 0, blue: 0)
}

struct LuminanceStats {
  let min: Double
  let max: Double
  let mean: Double
  let stddev: Double
  let count: Int

  static let empty = Self(min: 0, max: 0, mean: 0, stddev: 0, count: 0)
}

struct RegionSample {
  let averageColor: RGBColor
  let luminanceStats: LuminanceStats

  static let empty = Self(averageColor: .zero, luminanceStats: .empty)
}

enum SampleRegion {
  case top
  case center
}
