import CoreGraphics
import Foundation

extension HarnessMonitorStore {
  /// Lazily-instantiated decoder shared across all PRs. The actor's
  /// internal LRU caps decoded image memory at 64 MB by default.
  public var dependencyFileImageDecoder: DependencyUpdateImageDecoder {
    if let cached = sharedImageDecoderStorage.decoder { return cached }
    let decoder = DependencyUpdateImageDecoder()
    sharedImageDecoderStorage.decoder = decoder
    return decoder
  }

  /// Fetch the binary blob for an image file (PNG / JPEG / GIF / SVG),
  /// decode it off-main via the shared image decoder, and return a
  /// `PreparedImage`. SVG paths are handled by the shared SVG renderer
  /// the caller can integrate alongside.
  public func prepareImage(
    pullRequestID: String,
    repositoryID: String,
    oid: String,
    path: String,
    displayMaxDimension: Int = 800
  ) async -> DependencyUpdateImageDecoder.PreparedImage? {
    if let cached = await dependencyFileImageDecoder.cached(
      repositoryID: repositoryID,
      oid: oid,
      displayMaxDimension: displayMaxDimension
    ) {
      return cached
    }
    guard let client else { return nil }
    do {
      let blob = try await client.fetchDependencyUpdateFileBlob(
        request: DependencyUpdatesFilesBlobRequest(
          repositoryID: repositoryID,
          oid: oid,
          path: path
        )
      )
      guard let data = Data(base64Encoded: blob.contentBase64) else { return nil }
      return try await dependencyFileImageDecoder.decode(
        repositoryID: repositoryID,
        oid: oid,
        displayMaxDimension: displayMaxDimension,
        data: data
      )
    } catch {
      return nil
    }
  }
}

/// Box for the lazily-created shared decoder so we don't need to extend
/// the store with a new stored property. Keyed on the store's
/// `ObjectIdentifier` so multiple stores in the test process keep
/// independent decoders.
private final class DependencyFileImageDecoderStorage: @unchecked Sendable {
  var decoder: DependencyUpdateImageDecoder?
  init() {}
}

extension HarnessMonitorStore {
  fileprivate var sharedImageDecoderStorage: DependencyFileImageDecoderStorage {
    if let existing = DependencyFileImageDecoderRegistry.shared.storage(for: self) {
      return existing
    }
    let storage = DependencyFileImageDecoderStorage()
    DependencyFileImageDecoderRegistry.shared.register(storage, for: self)
    return storage
  }
}

@MainActor
private final class DependencyFileImageDecoderRegistry {
  static let shared = DependencyFileImageDecoderRegistry()

  private var entries: [ObjectIdentifier: DependencyFileImageDecoderStorage] = [:]

  fileprivate func storage(for store: HarnessMonitorStore) -> DependencyFileImageDecoderStorage? {
    entries[ObjectIdentifier(store)]
  }

  fileprivate func register(
    _ storage: DependencyFileImageDecoderStorage,
    for store: HarnessMonitorStore
  ) {
    entries[ObjectIdentifier(store)] = storage
  }
}
