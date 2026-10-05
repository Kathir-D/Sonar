import SwiftUI

/// The number beside a slider: drag the slider, or double-click the
/// number and type one, the way audio apps edit a parameter. Both
/// routes write the same binding, so whatever a drag gets - the
/// range clamp, the model's snapping, the Edit-menu undo entry - a
/// typed value gets too.
///
/// The field reads as static text until a second click arrives. A
/// single click is handed to the row instead of opening the editor,
/// so row behaviour is unchanged. Return commits, Escape throws the
/// edit away, and clicking anywhere else commits as well.
struct SliderNumberField: View {
    @Binding var value: Double
    /// Typed values outside this are clamped onto it.
    let range: ClosedRange<Double>
    /// Fraction digits shown.
    var decimals: Int = 1
    /// The stored value is the displayed one divided by this: 100
    /// for a slider over 0...1 that is shown as a percentage.
    var displayScale: Double = 1
    /// Snap typed values to a multiple of this. Sliders whose model
    /// snaps on write pass nothing and are snapped there instead.
    var step: Double? = nil
    /// Point size of the display. Pass the small system size where
    /// the row's number used to be a caption.
    var fontSize: CGFloat = NSFont.systemFontSize
    /// Fixed width, so a longer edit cannot push the unit label
    /// around.
    var width: CGFloat = 44
    /// What VoiceOver calls the field. The row's title, so the
    /// number is reachable on its own.
    var label: String = ""

    var body: some View {
        EditableNumber(
            value: $value,
            range: range,
            decimals: decimals,
            displayScale: displayScale,
            step: step,
            fontSize: fontSize,
            label: label
        )
        .frame(width: width, alignment: .trailing)
    }
}

private struct EditableNumber: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var decimals: Int = 1
    var displayScale: Double = 1
    var step: Double? = nil
    var fontSize: CGFloat = NSFont.systemFontSize
    var label: String = ""

    func makeNSView(context: Context) -> NumberField {
        let field = NumberField()
        // Editable, but it never draws itself as an editor: the
        // field editor supplies the editing surface, and until a
        // double-click asks for one this is just text.
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.alignment = .right
        field.font = NSFont.monospacedDigitSystemFont(
            ofSize: fontSize,
            weight: .regular
        )
        field.textColor = NSColor.secondaryLabelColor
        if !label.isEmpty {
            field.setAccessibilityLabel(label)
        }
        return field
    }

    func updateNSView(_ field: NumberField, context: Context) {
        // Set on every update, not once: the closures capture this
        // copy of the representable, and SwiftUI hands over a new
        // one whenever an input changes.
        field.commit = { [weak field] text in
            guard let field else { return }
            apply(text, to: field)
        }
        field.revertTo = { self.formatted(self.value) }
        // Never clobber what is being typed: an open field editor
        // means the user owns the string until the edit ends.
        if field.currentEditor() == nil {
            field.stringValue = formatted(value)
            // Changing the text of a field that has been edited once
            // does not always leave a fresh drawing behind: the number
            // goes blank and stays blank until something else forces a
            // redraw. Ask for it here, where the change is.
            field.needsDisplay = true
        }
    }

    /// Parse what was typed, fold it into the range and the step,
    /// and write it through the binding - the same write a drag
    /// makes. A string that does not parse, or one that parses back to
    /// the value already held, is thrown away rather than written: a
    /// click that opened the editor and lost it again is worth no
    /// Edit-menu entry. Either way the display goes back to the last
    /// value that was real.
    private func apply(_ text: String, to field: NumberField) {
        let typed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        var next: Double?
        // "nan" parses as a Double and survives min/max untouched, so it
        // would be stored and outlive the app. Anything not finite is as
        // unparseable as a stray letter.
        if let parsed = Double(typed), parsed.isFinite {
            var adjusted = parsed / displayScale
            adjusted = min(max(adjusted, range.lowerBound), range.upperBound)
            if let step, step > 0 {
                adjusted = (adjusted / step).rounded() * step
                adjusted = min(max(adjusted, range.lowerBound), range.upperBound)
            }
            next = adjusted
        }
        guard let next, next != value else {
            field.stringValue = formatted(value)
            return
        }
        value = next
        // The binding's setter may have snapped the write, so the
        // display is re-read from the binding rather than echoed
        // from what was typed.
        field.stringValue = formatted(value)
    }

    private func formatted(_ value: Double) -> String {
        let factor = pow(10, Double(decimals))
        let scaled = (value * displayScale * factor).rounded() / factor
        return String(format: "%.\(decimals)f", scaled)
    }
}

/// The text field proper. Editing opens on the second click only:
/// a single click is passed along so the row around the number keeps
/// its own behaviour, and a Form row is a List row, and those claim
/// their taps - a plain gesture here would never see one.
private final class NumberField: NSTextField {
    /// Write the typed number through the binding. Set by the
    /// representable on every update.
    var commit: ((String) -> Void)?
    /// The display text a cancelled edit is restored to.
    var revertTo: (() -> String)?
    /// Watches for Escape, alive only while an edit is open.
    private var escapeWatch: Any?
    /// Set while a cancel is unwinding, so the session it ends is not
    /// also read as a commit.
    private var cancelling = false
    /// Whether this field will take keyboard focus. See
    /// `acceptsFirstResponder`.
    private var acceptsFocus = false

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount > 1 else {
            // A single click belongs to the row. This field is not
            // accepting focus, so the row cannot hand it any, and an
            // editable field that never holds focus puts up no editor:
            // the number stays text and a stray keystroke goes
            // nowhere.
            acceptsFocus = false
            nextResponder?.mouseDown(with: event)
            return
        }
        // Take focus here and now rather than waiting to be offered it.
        // The Form offers it on its own schedule, and a field that
        // accepts focus in one go and gives it up in the next is left
        // holding an editor that takes no keys and draws nothing.
        acceptsFocus = true
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        // Select the whole number so typing replaces it instead of
        // appending to it.
        currentEditor()?.selectAll(nil)
    }

    /// False until a second click asks for an editor. The row would
    /// otherwise focus this field on any click in it, and an editable
    /// focused field is already an editor - one click from a number
    /// the user did not mean to change.
    override var acceptsFirstResponder: Bool { acceptsFocus }

    /// True only once a second click has asked for an editor. Kept as a
    /// stored answer rather than inferred from the event, because the
    /// focus the row hands over arrives on a later turn than the click
    /// that caused it.

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        // A fresh session must not inherit a cancel that never landed.
        cancelling = false
        // Escape is the one key the Form wants for itself - it takes
        // it to drop row focus - so the field editor's cancel never
        // runs and the session stays open, draft and all. A local
        // monitor is handed the key before the window passes it
        // anywhere else, which is the last place a cancel can be had.
        guard escapeWatch == nil else { return }
        escapeWatch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            // 53 is Escape on every layout; anything else, or an edit
            // that is not open, is none of this field's business.
            guard event.keyCode == 53 else { return event }
            guard let self, self.currentEditor() != nil else { return event }
            self.cancelEdit()
            // Passed on, so the Form still drops row focus:
            // swallowing it would leave SwiftUI thinking the number
            // holds focus while the window says otherwise.
            return event
        }
    }

    override func textDidEndEditing(_ notification: Notification) {
        if let escapeWatch {
            NSEvent.removeMonitor(escapeWatch)
            self.escapeWatch = nil
        }
        let wasCancelling = cancelling
        cancelling = false
        // The movement says how the edit ended. Escape ends it with
        // the cancel movement and the draft still in the field, so
        // the display is restored to the value the binding holds;
        // Return, tabbing away and clicking elsewhere all end it
        // some other way, and are commits. The flag is the same
        // signal, for the cancel this class performs itself - that
        // one ends the session whatever movement AppKit records.
        let movement =
            (notification.userInfo?[NSText.movementUserInfoKey] as? NSNumber)?
            .intValue ?? NSIllegalTextMovement
        if wasCancelling || movement == NSCancelTextMovement {
            if let restore = revertTo?() {
                stringValue = restore
            }
            return
        }
        commit?(stringValue)
    }

    /// Put the number back and take the editor down with it. Left
    /// open, the draft stays on screen while the model still holds the
    /// old value - the display and the value out of step, with
    /// nothing to press Return to fix it.
    private func cancelEdit() {
        guard let editor = currentEditor() else { return }
        cancelling = true
        if let restore = revertTo?() {
            // Both, because the draft lives in the editor and the
            // committed string in the field.
            stringValue = restore
            editor.string = restore
        }
        // AppKit's own cancel: it takes the editor down and reports the
        // cancel movement, so textDidEndEditing reads as one. Nothing
        // else touches the window's focus here - doing so leaves the
        // next field's editor stranded and unable to take a keystroke.
        abortEditing()
    }

    deinit {
        // An edit that never ended would leave the watch installed
        // for good.
        if let escapeWatch { NSEvent.removeMonitor(escapeWatch) }
    }
}
