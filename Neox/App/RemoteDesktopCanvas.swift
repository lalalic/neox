import SwiftUI
import UIKit

/// The remote image owns its touch recognizers, so two-finger navigation never
/// accidentally becomes a remote mouse drag.
struct RemoteDesktopCanvas: UIViewRepresentable {
    let image: CGImage
    let onClick: (CGFloat, CGFloat) -> Void
    let onRightClick: (CGFloat, CGFloat) -> Void
    let onDrag: (CGFloat, CGFloat, Bool, Bool) -> Void
    let onScroll: (CGFloat, CGFloat, Int, Int) -> Void

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.isMultipleTouchEnabled = true
        return view
    }

    func updateUIView(_ uiView: Surface, context: Context) {
        uiView.image = image
        uiView.onClick = onClick
        uiView.onRightClick = onRightClick
        uiView.onDrag = onDrag
        uiView.onScroll = onScroll
        uiView.setNeedsDisplay()
    }

    final class Surface: UIView, UIGestureRecognizerDelegate {
        var image: CGImage?
        var onClick: ((CGFloat, CGFloat) -> Void)?
        var onRightClick: ((CGFloat, CGFloat) -> Void)?
        var onDrag: ((CGFloat, CGFloat, Bool, Bool) -> Void)?
        var onScroll: ((CGFloat, CGFloat, Int, Int) -> Void)?

        private var zoom: CGFloat = 1
        private var offset = CGPoint.zero
        private var previousPan = CGPoint.zero
        private var previousPinchScale: CGFloat = 1
        private var dragging = false
        private var scrollRemainder = CGPoint.zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .systemBackground
            contentMode = .redraw
            installGestures()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func draw(_ rect: CGRect) {
            guard let image, let context = UIGraphicsGetCurrentContext() else { return }
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: imageRect())
            context.restoreGState()
        }

        private func imageRect() -> CGRect {
            guard let image, bounds.width > 0, bounds.height > 0 else { return .zero }
            let fit = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
            let width = CGFloat(image.width) * fit * zoom
            let height = CGFloat(image.height) * fit * zoom
            return CGRect(x: (bounds.width - width) / 2 + offset.x,
                          y: (bounds.height - height) / 2 + offset.y,
                          width: width, height: height)
        }

        private func normalized(_ point: CGPoint) -> CGPoint? {
            let rect = imageRect()
            guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
            return CGPoint(x: (point.x - rect.minX) / rect.width,
                           y: (point.y - rect.minY) / rect.height)
        }

        private func clampedPoint(_ point: CGPoint) -> CGPoint {
            let rect = imageRect()
            guard rect.width > 0, rect.height > 0 else { return .zero }
            return CGPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
                           y: min(1, max(0, (point.y - rect.minY) / rect.height)))
        }

        private func clampOffset() {
            let rect = imageRect()
            let maxX = max(0, (rect.width - bounds.width) / 2)
            let maxY = max(0, (rect.height - bounds.height) / 2)
            offset.x = min(maxX, max(-maxX, offset.x))
            offset.y = min(maxY, max(-maxY, offset.y))
        }

        private func applyZoom(_ target: CGFloat, around point: CGPoint) {
            let next = min(6, max(1, target))
            let old = zoom
            guard next != old else { return }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let factor = next / old
            offset.x = (point.x - center.x) * (1 - factor) + offset.x * factor
            offset.y = (point.y - center.y) * (1 - factor) + offset.y * factor
            zoom = next
            clampOffset()
            setNeedsDisplay()
        }

        private func installGestures() {
            let tap = UITapGestureRecognizer(target: self, action: #selector(click(_:)))
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleClick(_:)))
            doubleTap.numberOfTapsRequired = 2
            tap.require(toFail: doubleTap)
            addGestureRecognizer(tap)
            addGestureRecognizer(doubleTap)

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(rightClick(_:)))
            longPress.minimumPressDuration = 0.55
            addGestureRecognizer(longPress)
            tap.require(toFail: longPress)

            let singlePan = UIPanGestureRecognizer(target: self, action: #selector(remoteDrag(_:)))
            singlePan.minimumNumberOfTouches = 1
            singlePan.maximumNumberOfTouches = 1
            addGestureRecognizer(singlePan)

            let twoPan = UIPanGestureRecognizer(target: self, action: #selector(navigate(_:)))
            twoPan.minimumNumberOfTouches = 2
            twoPan.maximumNumberOfTouches = 2
            twoPan.delegate = self
            addGestureRecognizer(twoPan)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            pinch.delegate = self
            addGestureRecognizer(pinch)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            let pair = [gestureRecognizer, otherGestureRecognizer]
            return pair.contains(where: { $0 is UIPinchGestureRecognizer }) &&
                pair.contains(where: {
                    guard let pan = $0 as? UIPanGestureRecognizer else { return false }
                    return pan.minimumNumberOfTouches == 2
                })
        }

        @objc private func click(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let point = normalized(gesture.location(in: self)) else { return }
            onClick?(point.x, point.y)
        }

        @objc private func doubleClick(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            applyZoom(zoom > 1.05 ? 1 : 2.5, around: gesture.location(in: self))
        }

        @objc private func rightClick(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let point = normalized(gesture.location(in: self)) else { return }
            onRightClick?(point.x, point.y)
        }

        @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { previousPinchScale = 1 }
            if gesture.state == .began || gesture.state == .changed {
                applyZoom(zoom * gesture.scale / previousPinchScale, around: gesture.location(in: self))
                previousPinchScale = gesture.scale
            }
        }

        @objc private func remoteDrag(_ gesture: UIPanGestureRecognizer) {
            let point = clampedPoint(gesture.location(in: self))
            switch gesture.state {
            case .began:
                dragging = true
                onDrag?(point.x, point.y, true, false)
            case .changed:
                if dragging { onDrag?(point.x, point.y, false, false) }
            case .ended, .cancelled, .failed:
                if dragging { onDrag?(point.x, point.y, false, true) }
                dragging = false
            default: break
            }
        }

        @objc private func navigate(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: self)
            if gesture.state == .began {
                previousPan = .zero
                scrollRemainder = .zero
            }
            guard gesture.state == .began || gesture.state == .changed else { return }
            let delta = CGPoint(x: translation.x - previousPan.x, y: translation.y - previousPan.y)
            previousPan = translation
            if zoom > 1.01 {
                offset.x += delta.x
                offset.y += delta.y
                clampOffset()
                setNeedsDisplay()
            } else {
                scrollRemainder.x += delta.x
                scrollRemainder.y += delta.y
                let horizontal = Int(scrollRemainder.x / 28)
                let vertical = Int(scrollRemainder.y / 28)
                scrollRemainder.x -= CGFloat(horizontal * 28)
                scrollRemainder.y -= CGFloat(vertical * 28)
                let point = clampedPoint(gesture.location(in: self))
                if horizontal != 0 || vertical != 0 {
                    onScroll?(point.x, point.y, horizontal, vertical)
                }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            clampOffset()
        }
    }
}
