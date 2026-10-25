import AppKit
import SwiftUI
import SculptShowCore

/// The field editor owns unfinished text. Model/renderer edits happen only on Return.
struct ConfirmedNumberField: NSViewRepresentable {
    let value: Double
    let range: ClosedRange<Double>
    var decimals = 2
    var clock = false
    var label = "Value"
    let commit: (Double) -> Void

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var value: Double
        var range: ClosedRange<Double>
        var decimals: Int
        var clock: Bool
        var commit: (Double) -> Void
        private(set) var editing = false
        init(_ field: ConfirmedNumberField) { value = field.value; range = field.range; decimals = field.decimals; clock = field.clock; commit = field.commit }
        private func formatted(_ value: Double) -> String {
            if clock { return CueClock.format(value) }
            let formatter = NumberFormatter(); formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false; formatter.maximumFractionDigits = decimals
            return formatter.string(from: NSNumber(value: value)) ?? String(value)
        }
        func synchronize(_ field: NSTextField, value: Double) {
            self.value = value
            if !editing {
                let display = formatted(value)
                if field.stringValue != display { field.stringValue = display }
                field.textColor = SculptTheme.nsText
            }
        }
        func controlTextDidBeginEditing(_ obj: Notification) { editing = true }
        func controlTextDidEndEditing(_ obj: Notification) {
            editing = false
            if let field = obj.object as? NSTextField { field.stringValue = formatted(value); field.textColor = SculptTheme.nsText }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
                guard let next = clock ? CueClock.parse(text) : Double(text), next.isFinite, range.contains(next) else {
                    field.textColor = .systemOrange; field.toolTip = clock ? "Use HH:MM:SS:MMM within the cue timeline, then press Return." : "Enter a number from \(range.lowerBound) to \(range.upperBound), then press Return."
                    return true
                }
                value = next; editing = false
                field.stringValue = formatted(next); field.textColor = SculptTheme.nsText; field.toolTip = "Return confirms; leaving the field discards unfinished edits."
                commit(next)
                field.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                editing = false; field.stringValue = formatted(value); field.textColor = SculptTheme.nsText
                field.window?.makeFirstResponder(nil); return true
            }
            return false
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(); field.isEditable = true; field.isSelectable = true; field.isBezeled = true
        field.bezelStyle = .roundedBezel; field.backgroundColor = SculptTheme.nsField; field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.alignment = .right; field.delegate = context.coordinator
        field.setAccessibilityLabel(label); field.toolTip = "Return confirms; leaving the field discards unfinished edits."
        context.coordinator.synchronize(field, value: value); return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.range = range; context.coordinator.decimals = decimals; context.coordinator.clock = clock; context.coordinator.commit = commit
        context.coordinator.synchronize(field, value: value)
    }
}
