import Foundation

private struct TempoSearchResponse: Decodable {
  let traces: [TempoMatchedTrace]
}

private struct TempoMatchedTrace: Decodable {}

func localTempoSearchContainsSpan(
  serviceName: String,
  spanName: String,
  start: Int,
  end: Int
) async throws -> Bool {
  var components = URLComponents()
  (components.scheme, components.host, components.port, components.path) =
    ("http", "127.0.0.1", 3200, "/api/search")
  components.queryItems = [
    URLQueryItem(
      name: "q",
      value: "{resource.service.name=\"\(serviceName)\" && name=\"\(spanName)\"}"
    ),
    URLQueryItem(name: "start", value: String(start)),
    URLQueryItem(name: "end", value: String(end)),
  ]
  guard let requestURL = components.url else {
    throw URLError(.badURL)
  }
  let (data, response) = try await URLSession.shared.data(from: requestURL)
  guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
    throw URLError(.badServerResponse)
  }
  return try JSONDecoder().decode(TempoSearchResponse.self, from: data).traces.isEmpty == false
}

func waitForLocalTempoSpan(
  serviceName: String,
  spanName: String,
  start: Int,
  timeout: Duration = .seconds(15),
  pollingInterval: Duration = .milliseconds(250)
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout

  while clock.now < deadline {
    if try await localTempoSearchContainsSpan(
      serviceName: serviceName,
      spanName: spanName,
      start: start,
      end: Int(Date().timeIntervalSince1970) + 1
    ) {
      return
    }

    try await Task.sleep(for: pollingInterval)
  }

  throw URLError(.timedOut)
}
