import AppKit

enum HarnessTrackpadHistoryEffect {
  static let previewTravelFactor: CGFloat = 0.78
  static let commitTravelFactor: CGFloat = 1.04
  static let cancelDuration: CFTimeInterval = 0.16
  static let commitDuration: CFTimeInterval = 0.22

  static func backdropOpacity(for progress: CGFloat) -> Float {
    let clamped = min(max(progress, 0), 1)
    return Float(0.18 + (clamped * 0.42))
  }
}

extension HarnessTrackpadHistorySwipeNSView {
  func prepareTrackingLayersIfNeeded() {
    guard backdropLayer == nil, snapshotLayer == nil else {
      return
    }
    guard let layer else {
      return
    }

    let backdrop = CALayer()
    backdrop.frame = bounds
    var backdropColor = NSColor.underPageBackgroundColor.cgColor
    effectiveAppearance.performAsCurrentDrawingAppearance {
      backdropColor = NSColor.underPageBackgroundColor.cgColor
    }
    backdrop.backgroundColor = backdropColor
    backdrop.opacity = 0

    layer.addSublayer(backdrop)
    backdropLayer = backdrop

    if let snapshot = makeSnapshotLayer() {
      layer.addSublayer(snapshot)
      snapshotLayer = snapshot
    }
  }

  func cleanupTrackingLayers() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.backgroundColor = nil
    backdropLayer?.removeFromSuperlayer()
    snapshotLayer?.removeFromSuperlayer()
    backdropLayer = nil
    snapshotLayer = nil
    CATransaction.commit()
  }

  private func makeSnapshotLayer() -> CALayer? {
    guard bounds.width > 1, bounds.height > 1 else {
      return nil
    }
    guard let container = superview else {
      return nil
    }
    let captureRect = frame.integral
    guard let bitmap = container.bitmapImageRepForCachingDisplay(in: captureRect) else {
      return nil
    }

    let previousHidden = isHidden
    isHidden = true
    container.cacheDisplay(in: captureRect, to: bitmap)
    isHidden = previousHidden

    let image = NSImage(size: captureRect.size)
    image.addRepresentation(bitmap)

    let snapshot = CALayer()
    snapshot.frame = bounds
    snapshot.contents = image
    snapshot.contentsScale =
      monitoredWindow?.backingScaleFactor
      ?? window?.backingScaleFactor
      ?? NSScreen.main?.backingScaleFactor
      ?? 2
    snapshot.shadowOpacity = 0.18
    snapshot.shadowRadius = 20
    snapshot.shadowOffset = CGSize(width: -8, height: 0)
    snapshot.shadowPath = CGPath(rect: bounds, transform: nil)
    return snapshot
  }

  func applyTrackingEffect(gestureAmount: CGFloat) {
    let progress = max(-1, min(1, gestureAmount))
    let offset = progress * bounds.width * HarnessTrackpadHistoryEffect.previewTravelFactor

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    snapshotLayer?.transform = CATransform3DMakeTranslation(offset, 0, 0)
    snapshotLayer?.shadowOffset = CGSize(width: offset >= 0 ? -8 : 8, height: 0)
    backdropLayer?.opacity = HarnessTrackpadHistoryEffect.backdropOpacity(for: abs(progress))
    CATransaction.commit()
  }

  func animateTrackingLayers(
    to offset: CGFloat,
    duration: CFTimeInterval,
    timingFunctionName: CAMediaTimingFunctionName,
    completion: @escaping () -> Void
  ) {
    guard backdropLayer != nil || snapshotLayer != nil else {
      completion()
      return
    }

    let currentOffset =
      lastGestureAmount
      * bounds.width
      * HarnessTrackpadHistoryEffect.previewTravelFactor

    CATransaction.begin()
    CATransaction.setCompletionBlock(completion)

    if let snapshotLayer {
      let animation = CABasicAnimation(keyPath: "transform.translation.x")
      animation.fromValue = currentOffset
      animation.toValue = offset
      animation.duration = duration
      animation.timingFunction = CAMediaTimingFunction(name: timingFunctionName)
      snapshotLayer.add(animation, forKey: "trackpad-history-translate")
      snapshotLayer.transform = CATransform3DMakeTranslation(offset, 0, 0)
    }

    if let backdropLayer {
      let animation = CABasicAnimation(keyPath: "opacity")
      animation.fromValue = backdropLayer.presentation()?.opacity ?? backdropLayer.opacity
      animation.toValue = 0
      animation.duration = duration
      animation.timingFunction = CAMediaTimingFunction(name: timingFunctionName)
      backdropLayer.add(animation, forKey: "trackpad-history-backdrop")
      backdropLayer.opacity = 0
    }

    CATransaction.commit()
  }
}
