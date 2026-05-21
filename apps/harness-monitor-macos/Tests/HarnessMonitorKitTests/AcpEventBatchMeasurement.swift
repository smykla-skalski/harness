import Foundation

struct BatchMeasurement {
  let batchSize: Int
  let samplesNanoseconds: [UInt64]

  var medianNanoseconds: UInt64 {
    let sorted = samplesNanoseconds.sorted()
    return sorted[sorted.count / 2]
  }

  var histogram: BatchMeasurementHistogram {
    BatchMeasurementHistogram(samplesNanoseconds: samplesNanoseconds)
  }

  var histogramDescription: String {
    histogram.description
  }
}

struct BatchMeasurementHistogram {
  private static let buckets: [(label: String, upperBoundNanoseconds: UInt64)] = [
    ("<1ms", 1_000_000),
    ("1-2ms", 2_000_000),
    ("2-5ms", 5_000_000),
    ("5-10ms", 10_000_000),
    ("10-20ms", 20_000_000),
    ("20-50ms", 50_000_000),
  ]

  let bucketCounts: [(label: String, count: Int)]

  init(samplesNanoseconds: [UInt64]) {
    var counts = Self.buckets.map { (label: $0.label, count: 0) }
    var overflow = 0
    for sample in samplesNanoseconds {
      if let bucketIndex = Self.buckets.firstIndex(where: { sample < $0.upperBoundNanoseconds }) {
        counts[bucketIndex].count += 1
      } else {
        overflow += 1
      }
    }
    counts.append((label: "50ms+", count: overflow))
    bucketCounts = counts
  }

  var totalSamples: Int {
    bucketCounts.reduce(0) { $0 + $1.count }
  }

  var description: String {
    bucketCounts
      .compactMap { bucket -> String? in
        guard bucket.count >= 1 else {
          return nil
        }
        return "\(bucket.label)=\(bucket.count)"
      }
      .joined(separator: ", ")
  }
}
