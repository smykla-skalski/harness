import SwiftUI

struct HarnessMonitorSpinner: View {
  @ScaledMetric private var scaledSize: CGFloat
  private let tint: Color
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  init(size: CGFloat = 16, tint: Color = .secondary) {
    _scaledSize = ScaledMetric(wrappedValue: size)
    self.tint = tint
  }

  var body: some View {
    HarnessMonitorSpinnerRing(
      size: scaledSize,
      tint: tint,
      isAnimating: !reduceMotion
    )
    .frame(width: scaledSize, height: scaledSize)
    .accessibilityHidden(true)
  }
}

private struct HarnessMonitorSpinnerRing: NSViewRepresentable {
  let size: CGFloat
  let tint: Color
  let isAnimating: Bool

  func makeNSView(context _: Context) -> HarnessMonitorSpinnerRingView {
    HarnessMonitorSpinnerRingView()
  }

  func updateNSView(_ view: HarnessMonitorSpinnerRingView, context _: Context) {
    view.configure(
      size: size,
      tint: NSColor(tint),
      isAnimating: isAnimating
    )
  }
}

private final class HarnessMonitorSpinnerRingView: NSView {
  private static let spinAnimationKey = "harness-spinner-spin"
  private static let cycleDuration: CFTimeInterval = 0.8

  private let trackLayer = CAShapeLayer()
  private let arcLayer = CAShapeLayer()
  private var configuredTint = NSColor.secondaryLabelColor
  private var configuredSize: CGFloat = 16
  private var shouldAnimate = true

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    setupLayers()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    updateLayerGeometry()
  }

  func configure(size: CGFloat, tint: NSColor, isAnimating: Bool) {
    configuredSize = size
    configuredTint = tint
    shouldAnimate = isAnimating
    updateLayerGeometry()

    if isAnimating {
      startAnimating()
    } else {
      stopAnimating()
    }
  }

  private func setupLayers() {
    for layer in [trackLayer, arcLayer] {
      layer.fillColor = NSColor.clear.cgColor
      layer.lineCap = .round
      self.layer?.addSublayer(layer)
    }
  }

  private func updateLayerGeometry() {
    guard bounds.width > 0, bounds.height > 0 else {
      return
    }

    let lineWidth = max(2, configuredSize * 0.06)
    let radius = max(0, min(bounds.width, bounds.height) / 2 - lineWidth / 2)
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let path = CGPath(
      ellipseIn: CGRect(
        x: center.x - radius,
        y: center.y - radius,
        width: radius * 2,
        height: radius * 2
      ),
      transform: nil
    )

    trackLayer.frame = bounds
    trackLayer.path = path
    trackLayer.lineWidth = lineWidth
    trackLayer.strokeStart = 0
    trackLayer.strokeEnd = 1
    trackLayer.strokeColor = configuredTint.withAlphaComponent(0.12).cgColor

    arcLayer.frame = bounds
    arcLayer.path = path
    arcLayer.lineWidth = lineWidth
    arcLayer.strokeStart = 0.15
    arcLayer.strokeEnd = 0.85
    arcLayer.strokeColor = configuredTint.cgColor

    if shouldAnimate {
      startAnimating()
    }
  }

  private func startAnimating() {
    guard arcLayer.animation(forKey: Self.spinAnimationKey) == nil else {
      return
    }

    let animation = CABasicAnimation(keyPath: "transform.rotation.z")
    animation.fromValue = 0
    animation.toValue = CGFloat.pi * 2
    animation.duration = Self.cycleDuration
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    animation.isRemovedOnCompletion = false
    arcLayer.add(animation, forKey: Self.spinAnimationKey)
  }

  private func stopAnimating() {
    arcLayer.removeAnimation(forKey: Self.spinAnimationKey)
    arcLayer.setAffineTransform(.identity)
  }
}
