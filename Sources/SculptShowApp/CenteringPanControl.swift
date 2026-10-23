import SwiftUI
import AppKit

struct CenteringPanControl: NSViewRepresentable {
    @Binding var value: Double
    let label: String
    final class Slider: NSSlider {
        private var lastDown: TimeInterval = -.infinity
        private var lastPoint = NSPoint.zero
        private var pendingReset = false
        private var interaction = 0
        private func center() { doubleValue = 0; sendAction(action, to: target) }
        override func mouseUp(with event: NSEvent) {
            super.mouseUp(with: event)
            if pendingReset { pendingReset = false; center() }
        }
        override func mouseDown(with event: NSEvent) {
            interaction += 1; pendingReset = false
            let point = event.locationInWindow
            let nearby = hypot(point.x - lastPoint.x, point.y - lastPoint.y) < 5
            let repeated = nearby && event.timestamp - lastDown <= NSEvent.doubleClickInterval
            lastDown = event.timestamp; lastPoint = point
            if event.clickCount >= 2 || repeated {
                pendingReset = true; center()
                let token = interaction
                // NSSliderCell may finish its previous tracking action after this click.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    guard let self, self.interaction == token else { return }; self.center()
                }
                return
            }
            super.mouseDown(with: event)
        }
    }
    final class Coordinator: NSObject {
        var parent: CenteringPanControl
        init(_ parent: CenteringPanControl) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.doubleValue }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Slider {
        let slider = Slider(value: value, minValue: -1, maxValue: 1, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.controlSize = .mini; slider.isContinuous = true
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }
    func updateNSView(_ slider: Slider, context: Context) {
        context.coordinator.parent = self
        slider.doubleValue = value; slider.setAccessibilityLabel(label)
        slider.toolTip = "Drag to pan. Double-click anywhere on this slider to center; or click the PAN value above."
    }
}
