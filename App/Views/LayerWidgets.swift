import AppKit
import SwiftUI

// Rings, gauges, bars and meters drawn with Core Animation layers. Their motion is a layer
// property animation (strokeEnd, bounds) that the render server interpolates, so a smooth
// 0.5 s transition costs the app nothing per frame. The same widgets animated in SwiftUI kept the
// app redrawing at 120 Hz: ~280 ms/s of CPU with a panel open versus ~34 without motion.

/// Base view: layer-backed, colours resolved for the current appearance, animated property changes.
class AnimatedLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        update(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update(animated: false)
    }

    /// Subclasses lay out and set their layers' properties here.
    func update(animated: Bool) {}

    func cg(_ color: NSColor) -> CGColor {
        var c = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { c = color.cgColor }
        return c
    }

    /// Runs property changes as one render-server animation (or instantly).
    func transaction(animated: Bool, _ body: () -> Void) {
        CATransaction.begin()
        if animated && Motion.enabled && window != nil {
            CATransaction.setAnimationDuration(0.5)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1))
        } else {
            CATransaction.setDisableActions(true)
        }
        body()
        CATransaction.commit()
    }
}

// MARK: - Arc (ring or gauge)

/// Segments along an arc. `sweep` is the arc's share of a full circle (1 for a ring, 0.75 for a
/// gauge), starting at `startAngle` and running clockwise.
final class ArcLayerView: AnimatedLayerView {
    var parts: [(Float, NSColor)] = []
    var lineWidth: CGFloat = 11
    var sweep: CGFloat = 1
    var startAngle: CGFloat = -90
    var roundCaps = false
    var gap: CGFloat = 0.006

    private let track = CAShapeLayer()
    private var segments: [CAShapeLayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        track.fillColor = nil
        layer?.addSublayer(track)
    }

    override func update(animated: Bool) {
        transaction(animated: false) {
            let r = min(bounds.width, bounds.height) / 2 - lineWidth / 2
            guard r > 0 else { return }
            // Drawn clockwise from the start angle (layer y is up, so angles are negated).
            let path = CGMutablePath()
            let start = -startAngle * .pi / 180
            path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: r, startAngle: start,
                        endAngle: start - sweep * 2 * .pi, clockwise: true)
            track.path = path
            track.lineWidth = lineWidth
            track.lineCap = roundCaps ? .round : .butt
            track.strokeColor = cg(NSColor.labelColor.withAlphaComponent(0.09))
            while segments.count < parts.count {
                let s = CAShapeLayer()
                s.fillColor = nil
                s.strokeEnd = 0
                layer?.addSublayer(s)
                segments.append(s)
            }
            while segments.count > parts.count { segments.removeLast().removeFromSuperlayer() }
            for (s, part) in zip(segments, parts) {
                s.path = path
                s.lineWidth = lineWidth
                s.lineCap = roundCaps ? .round : .butt
                s.strokeColor = cg(part.1)
            }
        }
        // Only the fill amounts animate.
        transaction(animated: animated) {
            let multi = parts.filter { $0.0 > 0.005 }.count > 1
            var start: CGFloat = 0
            for (s, part) in zip(segments, parts) {
                let f = CGFloat(min(max(part.0, 0), 1))
                s.strokeStart = start
                s.strokeEnd = max(start, min(1, start + f - (multi ? gap : 0)))
                start += f
            }
        }
    }
}

struct ArcLayer: NSViewRepresentable {
    var parts: [(Float, Color)]
    var lineWidth: CGFloat
    var sweep: CGFloat = 1
    var startAngle: CGFloat = -90
    var roundCaps = false

    func makeNSView(context: Context) -> ArcLayerView { ArcLayerView() }

    func updateNSView(_ v: ArcLayerView, context: Context) {
        let newParts = parts.map { ($0.0, NSColor($0.1)) }
        let changed = newParts.map(\.0) != v.parts.map(\.0)
        v.parts = newParts
        v.lineWidth = lineWidth
        v.sweep = sweep
        v.startAngle = startAngle
        v.roundCaps = roundCaps
        v.update(animated: changed)
    }
}

// MARK: - Bars

/// Per-core columns, laid out like Stats' column chart (measured from its source): full width with
/// 2 pt gaps, corners rounded at most 3 pt, a 50 %→100 % gradient, a faint track, and the core's
/// load shown while the pointer is over it. Heights animate in the render server.
final class BarsLayerView: AnimatedLayerView {
    var values: [Float] = []
    var colors: [NSColor] = []
    private var tracks: [CALayer] = []
    private var bars: [CAGradientLayer] = []
    private let tip = CATextLayer()
    private var hovered: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        tip.fontSize = 10
        tip.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        tip.alignmentMode = .center
        tip.cornerRadius = 4
        tip.isHidden = true
        tip.zPosition = 10
        layer?.addSublayer(tip)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        hovered = tracks.firstIndex { $0.frame.minX - 1 <= x && x <= $0.frame.maxX + 1 }
        update(animated: false)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        update(animated: false)
    }

    override func update(animated: Bool) {
        let n = values.count
        transaction(animated: false) {
            while bars.count < n {
                let t = CALayer(), b = CAGradientLayer()
                b.anchorPoint = CGPoint(x: 0.5, y: 0)
                b.startPoint = CGPoint(x: 0.5, y: 0)
                b.endPoint = CGPoint(x: 0.5, y: 1)
                layer?.insertSublayer(t, below: tip)
                layer?.insertSublayer(b, below: tip)
                tracks.append(t)
                bars.append(b)
            }
            while bars.count > n {
                bars.removeLast().removeFromSuperlayer()
                tracks.removeLast().removeFromSuperlayer()
            }
            guard n > 0 else { return }
            let spacing: CGFloat = 2
            let w = (bounds.width - spacing * CGFloat(n - 1)) / CGFloat(n)
            let radius = min(3, w / 2)
            for i in 0..<n {
                let frame = CGRect(x: CGFloat(i) * (w + spacing), y: 0, width: w, height: bounds.height)
                tracks[i].frame = frame
                tracks[i].cornerRadius = radius
                tracks[i].backgroundColor = cg(NSColor.labelColor.withAlphaComponent(hovered == i ? 0.14 : 0.07))
                bars[i].position = CGPoint(x: frame.midX, y: 0)
                bars[i].cornerRadius = radius
                let c = i < colors.count ? colors[i] : .controlAccentColor
                bars[i].colors = [cg(c).copy(alpha: 0.5) as Any, cg(c) as Any]
            }
            if let h = hovered, h < n {
                tip.string = "\(Int((values[h] * 100).rounded()))%"
                tip.foregroundColor = cg(.labelColor)
                tip.backgroundColor = cg(NSColor.windowBackgroundColor.withAlphaComponent(0.9))
                tip.contentsScale = window?.backingScaleFactor ?? 2
                let tw: CGFloat = 32
                let x = min(max(tracks[h].frame.midX - tw / 2, 0), bounds.width - tw)
                tip.frame = CGRect(x: x, y: bounds.height - 15, width: tw, height: 14)
                tip.isHidden = false
            } else {
                tip.isHidden = true
            }
        }
        transaction(animated: animated) {
            for (i, b) in bars.enumerated() {
                let w = tracks[i].frame.width
                let v = CGFloat(min(max(values[i], 0), 1))
                // Like Stats: nothing at 0 %, otherwise at least a sliver so light load is visible.
                b.bounds = CGRect(x: 0, y: 0, width: w, height: v > 0.001 ? max(2, bounds.height * v) : 0)
            }
        }
    }
}

struct BarsLayer: NSViewRepresentable {
    var values: [Float]
    var colors: [Color]

    func makeNSView(context: Context) -> BarsLayerView { BarsLayerView() }

    func updateNSView(_ v: BarsLayerView, context: Context) {
        let changed = values != v.values
        v.values = values
        v.colors = colors.map { NSColor($0) }
        v.update(animated: changed)
    }
}

// MARK: - Meter

/// Horizontal capsule meter with a gradient fill that scales to the value.
final class MeterLayerView: AnimatedLayerView {
    var value: Float = 0
    var tint: NSColor = .controlAccentColor
    private let track = CALayer()
    private let fill = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
    }

    override func update(animated: Bool) {
        transaction(animated: false) {
            track.frame = bounds
            track.cornerRadius = bounds.height / 2
            track.backgroundColor = cg(NSColor.labelColor.withAlphaComponent(0.09))
            fill.position = CGPoint(x: 0, y: bounds.midY)
            fill.cornerRadius = bounds.height / 2
            fill.colors = [cg(tint).copy(alpha: 0.75) as Any, cg(tint) as Any]
        }
        transaction(animated: animated) {
            fill.bounds = CGRect(x: 0, y: 0, width: max(bounds.height, bounds.width * CGFloat(min(max(value, 0), 1))), height: bounds.height)
        }
    }
}

struct MeterLayer: NSViewRepresentable {
    var value: Float
    var tint: Color

    func makeNSView(context: Context) -> MeterLayerView { MeterLayerView() }

    func updateNSView(_ v: MeterLayerView, context: Context) {
        let changed = value != v.value
        v.value = value
        v.tint = NSColor(tint)
        v.update(animated: changed)
    }
}
