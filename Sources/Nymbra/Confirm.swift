import AppKit

/// Ask a question that cannot be skipped.
///
/// A tab and a window both ask it, so it lives with neither. It is modal and
/// blocking on purpose: closing something with work still in it is not a decision
/// to take in the background. A headless test cannot answer a modal question, so
/// it switches the confirmation off rather than faking a click — which is why the
/// setting exists and why the tests are explicit about setting it.
func confirm(what: String, detail: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = what
    alert.informativeText = detail
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Close")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
}
