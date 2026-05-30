import AVFoundation
import HarnessMonitorCrypto
import SwiftUI
import UIKit
import VisionKit

struct MobilePairingScannerView: View {
  let onPairingURL: (URL) -> Void

  @Environment(\.dismiss)
  private var dismiss
  @Environment(\.openURL)
  private var openURL
  @Environment(\.scenePhase)
  private var scenePhase
  @State private var cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
  @State private var startScanningFailed = false
  @State private var manualEntry = ""

  var body: some View {
    switch availability {
    case .scanning:
      MobilePairingDataScanner(onPairingURL: onPairingURL) {
        startScanningFailed = true
      }
      .ignoresSafeArea()
    case .needsPermission, .denied, .unsupported:
      fallback
    }
  }

  private var fallback: some View {
    NavigationStack {
      List {
        Section {
          MobilePairingScannerNotice(availability: availability)
        }
        if availability == .needsPermission {
          Section {
            Button("Allow Camera Access") {
              Task {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
              }
            }
          }
        }
        if availability == .denied {
          Section {
            Button("Open iOS Settings") {
              guard let url = URL(string: UIApplication.openSettingsURLString) else {
                return
              }
              openURL(url)
            }
          }
        }
        Section("Paste pairing link") {
          TextField("harness://pair...", text: $manualEntry, axis: .vertical)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(2...4)
          Button("Pair") {
            guard let url = parsedManualURL else {
              return
            }
            onPairingURL(url)
          }
          .disabled(parsedManualURL == nil)
        }
      }
      .navigationTitle("Pair Mac")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active {
          cameraAuthorization = AVCaptureDevice.authorizationStatus(for: .video)
        }
      }
    }
  }

  private var availability: MobilePairingScannerAvailability {
    if startScanningFailed {
      return .unsupported
    }
    guard DataScannerViewController.isSupported else {
      return .unsupported
    }
    switch cameraAuthorization {
    case .authorized:
      return DataScannerViewController.isAvailable ? .scanning : .unsupported
    case .notDetermined:
      return .needsPermission
    case .denied, .restricted:
      return .denied
    @unknown default:
      return .denied
    }
  }

  private var parsedManualURL: URL? {
    MobilePairingScannerView.pairingURL(from: manualEntry)
  }

  static func pairingURL(from text: String) -> URL? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
      url.scheme == MobilePairingInvitationCodec.urlScheme,
      url.host == MobilePairingInvitationCodec.urlHost
    else {
      return nil
    }
    return url
  }
}

enum MobilePairingScannerAvailability: Equatable {
  case scanning
  case needsPermission
  case denied
  case unsupported
}

private struct MobilePairingScannerNotice: View {
  let availability: MobilePairingScannerAvailability

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.headline)
        Text(message)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: iconName)
        .foregroundStyle(.orange)
    }
    .accessibilityElement(children: .combine)
  }

  private var title: String {
    switch availability {
    case .needsPermission:
      String(localized: "Camera access needed")
    case .denied:
      String(localized: "Camera access denied")
    case .unsupported:
      String(localized: "Scanning unavailable")
    case .scanning:
      ""
    }
  }

  private var message: String {
    switch availability {
    case .needsPermission:
      String(
        localized: "Allow camera access to scan the Mac pairing QR code, or paste the link below")
    case .denied:
      String(
        localized:
          "Enable camera access in iOS Settings to scan the pairing QR code, or paste the link below"
      )
    case .unsupported:
      String(
        localized: "This device cannot scan QR codes. Paste the pairing link from the Mac below")
    case .scanning:
      ""
    }
  }

  private var iconName: String {
    switch availability {
    case .denied:
      "video.slash"
    default:
      "qrcode.viewfinder"
    }
  }
}

private struct MobilePairingDataScanner: UIViewControllerRepresentable {
  let onPairingURL: (URL) -> Void
  let onStartFailed: () -> Void

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
    do {
      try controller.startScanning()
    } catch {
      Task { @MainActor in
        onStartFailed()
      }
    }
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
          let url = MobilePairingScannerView.pairingURL(from: payload)
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
