import Foundation

/// Whether a command that has just finished is worth interrupting somebody for.
///
/// This is the rule, kept away from the notification that obeys it. It is a pure
/// function of facts — how long the command ran, what it exited with, and whether
/// the person was already looking — for two reasons: a rule that lives next to
/// `UNUserNotificationCenter` can only be tested by posting notifications, and
/// `UNUserNotificationCenter` cannot be called at all outside an application
/// bundle. See the note on `TerminalWindow.deliver`.
///
/// The mistake worth guarding against is a terminal that will not stop talking.
/// A shell runs dozens of commands a minute, so:
///
/// - **nothing shorter than the threshold is announced, however it went.** A
///   `cd` that took 4ms is not news, and neither is a `git status`;
/// - **nothing is announced for a command the person watched finish.** If it was
///   in the tab in front of them in an active application, they saw it;
/// - **a failing command is not special-cased.** Failing fast is what a typo
///   does, and "everything you mistype gets a notification" is the firehose this
///   whole milestone is written against. A failure that took a long time is
///   announced, and the body says so.
public enum CommandAttention {

    /// Something worth saying about a command that has finished.
    public struct Announcement: Equatable, Sendable {
        /// What to call it: the tab's name, so a notification about a build in
        /// one tab is not mistaken for one about a build in another.
        public var title: String
        /// How long it took, and — when it did not succeed — what it exited with.
        public var body: String
    }

    /// What to announce about a command that has finished, or `nil` for silence.
    ///
    /// - Parameters:
    ///   - status: the shell's exit status, or `nil` when it reported none. The
    ///     two are different facts, but not different *decisions*: a command that
    ///     ran for a minute is worth mentioning either way.
    ///   - seconds: how long the command ran.
    ///   - threshold: the shortest command worth announcing. `0` means never.
    ///   - isWatched: the person was looking at this tab, in an active
    ///     application, when the command finished.
    ///   - subject: what to call the tab.
    public static func announcement(
        status: Int32?,
        seconds: Double,
        threshold: Double,
        isWatched: Bool,
        subject: String
    ) -> Announcement? {
        guard threshold > 0, seconds >= threshold, !isWatched else { return nil }
        return Announcement(
            title: subject.isEmpty ? "Command finished" : subject,
            body: describe(status: status, seconds: seconds)
        )
    }

    /// "Finished in 1m 12s." — or, when it went badly, "Exited 1 after 1m 12s."
    static func describe(status: Int32?, seconds: Double) -> String {
        let took = duration(seconds)
        switch status {
        case .some(0), .none:
            return "Finished in \(took)."
        case let .some(status):
            return "Exited \(status) after \(took)."
        }
    }

    /// A duration somebody reads at a glance: "0.4s", "8.4s", "1m 12s", "2h 05m".
    ///
    /// Sub-minute values keep one decimal rather than rounding to zero: "0s" for
    /// a command that took 400ms reads like a bug in the notification rather than
    /// a quick command.
    static func duration(_ seconds: Double) -> String {
        guard seconds >= 60 else { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds.rounded())
        let minutes = whole / 60
        guard minutes >= 60 else { return "\(minutes)m \(String(format: "%02d", whole % 60))s" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
}

/// Times the command a shell is running, from the marks it sends.
///
/// `C` says a command is about to run and `D` says it has finished, so the gap
/// between the two *is* the duration. Nothing has to be parsed out of the
/// command line, and nothing depends on the line editor: the shell already knows
/// when it started and stopped, and these are the two marks it sends about it.
///
/// `A` and `B` are ignored — they are about prompts, not commands. A `D` with no
/// `C` before it (a shell that reports a status for something Nymbra never saw
/// start) times nothing rather than assuming a duration.
///
/// A value type with `now` passed in, so a test can time a ten-minute build
/// without waiting ten minutes for it.
public struct CommandTimer: Sendable {

    /// Did a command start and then finish?
    public struct Finished: Equatable, Sendable {
        /// The exit status, when the shell reported one.
        public var status: Int32?
        /// How long the command took.
        public var seconds: Double

        public init(status: Int32?, seconds: Double) {
            self.status = status
            self.seconds = seconds
        }
    }

    private var startedAt: Date?

    public init() {}

    /// Feed the timer one mark. Returns something only when a command finished.
    public mutating func note(_ mark: ShellMark, now: Date = Date()) -> Finished? {
        switch mark {
        case .commandExecuted:
            // A second `C` without a `D` between them means there is no `D` we
            // are still timing — restart rather than measure across the gap.
            startedAt = now
            return nil
        case let .commandFinished(status):
            guard let started = startedAt else { return nil }
            startedAt = nil
            return Finished(status: status, seconds: now.timeIntervalSince(started))
        case .promptStart, .commandStart:
            return nil
        }
    }
}
