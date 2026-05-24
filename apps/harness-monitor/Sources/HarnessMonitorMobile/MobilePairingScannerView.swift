import HarnessMonitorCrypto
import SwiftUI
import VisionKit

struct MobilePairingScannerView: UIViewControllerRepresentable {
  let onPairingURL: (URL) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onPairingURL: onPairingURL)
  }

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let controller = DataScannerViewController(
      recognizedDataTypes: [.barcode(symbologies: [.qr])],
      qualityLevel: .balanced,
      recognizesMultipleItems: false,
      isHighFrameRateTrackingEnabled: false,
      isPinchToZoomEnabled: true,
      isGuidanceEnabled: true,
      isHighlightingEnabled: true
    )
    controller.delegate = context.coordinator
    try? controller.startScanning()
    return controller
  }

  func updateUIViewController(
    _ uiViewController: DataScannerViewController,
    context: Context
  ) {}

  static func dismantleUIViewController(
    _ uiViewController: DataScannerViewController,
    coordinator: Coordinator
  ) {
    uiViewController.stopScanning()
  }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    private let onPairingURL: (URL) -> Void
    private var didSubmitURL = false

    init(onPairingURL: @escaping (URL) -> Void) {
      self.onPairingURL = onPairingURL
    }

    func dataScanner(
      _ dataScanner: DataScannerViewController,
      didAdd addedItems: [RecognizedItem],
      allItems: [RecognizedItem]
    ) {
      handle(addedItems)
    }

    func dataScanner(
      _ dataScanner: DataScannerViewController,
      didUpdate updatedItems: [RecognizedItem],
      allItems: [RecognizedItem]
    ) {
      handle(updatedItems)
    }

    private func handle(_ items: [RecognizedItem]) {
      guard !didSubmitURL else {
        return
      }
      for item in items {
        guard case .barcode(let barcode) = item,
          let payload = barcode.payloadStringValue,
          let url = URL(string: payload),
          url.scheme == MobilePairingInvitationCodec.urlScheme,
          url.host == MobilePairingInvitationCodec.urlHost
        else {
          continue
        }
        didSubmitURL = true
        onPairingURL(url)
        return
      }
    }
  }
}
