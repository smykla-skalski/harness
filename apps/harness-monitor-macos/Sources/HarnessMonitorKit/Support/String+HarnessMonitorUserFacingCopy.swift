public extension String {
  var harnessMonitorTrimmedTrailingPeriod: String {
    guard self != ".", self.hasSuffix("."), !self.hasSuffix("...") else {
      return self
    }
    return String(self.dropLast())
  }
}
