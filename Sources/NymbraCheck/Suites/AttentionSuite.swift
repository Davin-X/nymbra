import Foundation
import NymbraCore

/// When a finished command is worth interrupting somebody for, and how long it took.
///
/// The rule is tested here rather than through a real notification, because a real
/// notification cannot be posted from this process at all: `make test` runs a bare
/// executable, and `UNUserNotificationCenter.current()` aborts outside an
/// application bundle. So what is pinned here is the *decision*, and the delivery
/// is one line at the edge that the app replaces with a capture in `--notify-test`.
func attentionSuite(_ h: Harness) {
    h.suite("attention")

    // MARK: The threshold — the difference between a notification and a firehose

    h.expect(CommandAttention.announcement(status: 0, seconds: 9.9, threshold: 10,
                                           isWatched: false, subject: "zsh") == nil,
             "a command that finished under the threshold is not announced")

    h.expect(CommandAttention.announcement(status: 0, seconds: 10, threshold: 10,
                                           isWatched: false, subject: "zsh") != nil,
             "a command that took exactly the threshold is announced")

    h.expect(CommandAttention.announcement(status: 0, seconds: 3_600, threshold: 0,
                                           isWatched: false, subject: "zsh") == nil,
             "a threshold of zero means never, not every command")

    h.expect(CommandAttention.announcement(status: 0, seconds: 3_600, threshold: 10,
                                           isWatched: true, subject: "zsh") == nil,
             "a command the person watched finish is not announced at them")

    // A failure is not special-cased, and this is the rule most likely to be
    // "improved" by somebody who has just been annoyed by a slow build: every
    // typo fails in milliseconds, so announcing failures would announce
    // everything anybody ever mistyped.
    h.expect(CommandAttention.announcement(status: 1, seconds: 0.02, threshold: 10,
                                           isWatched: false, subject: "zsh") == nil,
             "a command that failed fast is not announced either, or every typo would be")

    h.expect(CommandAttention.announcement(status: 1, seconds: 90, threshold: 10,
                                           isWatched: false, subject: "zsh") != nil,
             "a command that failed slowly is announced")

    // MARK: What it says

    let ok = CommandAttention.announcement(status: 0, seconds: 61.2, threshold: 10,
                                           isWatched: false, subject: "bash \u{2014} nymbra")
    h.equal(ok?.title, "bash \u{2014} nymbra", "the tab's own name, so two tabs are not confused")
    h.equal(ok?.body, "Finished in 1m 01s.", "a finished command says how long it took")

    let failed = CommandAttention.announcement(status: 7, seconds: 61.2, threshold: 10,
                                               isWatched: false, subject: "zsh")
    h.equal(failed?.body, "Exited 7 after 1m 01s.", "a failure leads with the status")

    let unreported = CommandAttention.announcement(status: nil, seconds: 61.2, threshold: 10,
                                                  isWatched: false, subject: "zsh")
    h.equal(unreported?.body, "Finished in 1m 01s.",
            "a shell that reported no status is not reported as having failed")

    let anonymous = CommandAttention.announcement(status: 0, seconds: 61.2, threshold: 10,
                                                 isWatched: false, subject: "")
    h.equal(anonymous?.title, "Command finished", "a tab with no name still reads as a sentence")

    // MARK: Durations people can read

    func body(_ seconds: Double) -> String {
        CommandAttention.announcement(status: 0, seconds: seconds, threshold: 0.001,
                                      isWatched: false, subject: "zsh")?.body ?? ""
    }

    h.equal(body(0.42), "Finished in 0.4s.", "a fraction of a second keeps its decimal")
    h.equal(body(8.44), "Finished in 8.4s.", "seconds are rounded to one decimal")
    h.equal(body(59.94), "Finished in 59.9s.", "just under a minute is still shown in seconds")
    h.equal(body(60), "Finished in 1m 00s.", "a minute is minutes and seconds")
    h.equal(body(3_600), "Finished in 1h 00m.", "an hour is hours and minutes")
    h.equal(body(7_325), "Finished in 2h 02m.", "hours pad the minutes")
    h.equal(body(59.94).contains("0s."), false,
            "a quick command never reads as having taken no time at all")

    // MARK: Timing a command from the shell's own marks

    let t0 = Date(timeIntervalSince1970: 1_000_000)

    var timer = CommandTimer()
    h.expect(timer.note(.promptStart, now: t0) == nil, "a prompt is not a command")
    h.expect(timer.note(.commandStart, now: t0) == nil, "the end of a prompt is not a command")
    h.expect(timer.note(.commandFinished(0), now: t0.addingTimeInterval(5)) == nil,
             "a finish with nothing started times nothing rather than inventing a duration")

    timer = CommandTimer()
    h.expect(timer.note(.commandExecuted, now: t0) == nil,
             "a command starting is not a command finishing")
    h.equal(timer.note(.commandFinished(0), now: t0.addingTimeInterval(12)),
            CommandTimer.Finished(status: 0, seconds: 12),
            "the gap between C and D is the command's duration")
    h.expect(timer.note(.commandFinished(0), now: t0.addingTimeInterval(99)) == nil,
             "the same finish is not reported twice")

    timer = CommandTimer()
    _ = timer.note(.commandExecuted, now: t0)
    h.equal(timer.note(.commandFinished(7), now: t0.addingTimeInterval(3)),
            CommandTimer.Finished(status: 7, seconds: 3),
            "a failing command is timed and carries its status")

    timer = CommandTimer()
    _ = timer.note(.commandExecuted, now: t0)
    _ = timer.note(.commandFinished(0), now: t0.addingTimeInterval(5))
    _ = timer.note(.commandExecuted, now: t0.addingTimeInterval(20))
    h.equal(timer.note(.commandFinished(0), now: t0.addingTimeInterval(22)),
            CommandTimer.Finished(status: 0, seconds: 2),
            "each command is timed from its own start, not the first one's")

    timer = CommandTimer()
    h.expect(timer.note(.commandExecuted, now: t0) == nil, "a command starts")
    h.expect(timer.note(.commandExecuted, now: t0.addingTimeInterval(30)) == nil,
             "a second start with no finish in between replaces the first")
    h.equal(timer.note(.commandFinished(nil), now: t0.addingTimeInterval(31)),
            CommandTimer.Finished(status: nil, seconds: 1),
            "and is measured from the second, not across the abandoned gap")
}
