import AppKit
import Foundation
import NymbraCore
import NymbraInput

// Helpers shared by the headless proofs.
//
// CI cannot look at a window, so correctness is demonstrated by driving the
// emulator with real bytes and printing what the screen model made of them.
// Dispatched from `main.swift` by command-line flag.

/// `1` or `0`, which is how every proof prints a yes or no.
func flag(_ value: Bool) -> Int { value ? 1 : 0 }

/// A key event of the kind the application routes.
///
/// `characters` is what a field editor inserts; the modifiers are what a shortcut
/// is made of; the window number is which field editor is listening.
func keyEvent(
    _ keyCode: UInt16,
    _ characters: String,
    modifiers: NSEvent.ModifierFlags = [],
    windowNumber: Int = 0
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
    )!
}

/// The view's pixels, row by row, as the renderer drew them.
func pixels(of view: NSView) -> [UInt8] {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.bitmapData else { return [] }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(rep.bytesPerRow * rep.pixelsHigh)
    for row in 0..<rep.pixelsHigh {
        bytes.append(contentsOf: UnsafeBufferPointer(start: data + row * rep.bytesPerRow,
                                                     count: rep.bytesPerRow))
    }
    return bytes
}

/// How many bytes two renders differ by. Zero means the same picture twice.
func differingBytes(_ one: [UInt8], _ other: [UInt8]) -> Int {
    guard !one.isEmpty, one.count == other.count else { return -1 }
    var count = 0
    for index in 0..<one.count where one[index] != other[index] { count += 1 }
    return count
}

func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
    let filler = String(repeating: " ", count: max(0, width - text.count))
    return right ? filler + text : text + filler
}

/// The marks a shell sent, collected off the delivery queue.
final class MarkLog {
    private let lock = NSLock()
    private var marks: [ShellMark] = []

    func append(_ mark: ShellMark) {
        lock.lock()
        defer { lock.unlock() }
        marks.append(mark)
    }

    var all: [ShellMark] {
        lock.lock()
        defer { lock.unlock() }
        return marks
    }
}

/// What the terminal actually saw, for the failure that needs it.
///
/// "no prompt in 20 seconds" does not say whether zsh never started, started and
/// fell over a generated startup file, or ran perfectly and simply did not
/// report. The screen is the difference between those, and without it the
/// failure reads as "the terminal is broken".
func reportShellIntegration(_ terminal: Terminal, queue: DispatchQueue,
                                    log: MarkLog, reason: String) {
    let screen = queue.sync {
        (0..<terminal.screen.rows).map { terminal.screen.rowText($0) }.joined(separator: "\n")
    }
    FileHandle.standardError.write(
        Data("nymbra: \(reason)\n--- screen ---\n\(screen)\n--- marks: \(log.all) ---\n".utf8))
}
