import Foundation

/// A record of one command run in the terminal.
///
/// The shell tells the terminal when a command starts (`C` mark) and when it
/// finishes (`D` mark). The command line travels with `C`; the exit status
/// travels with `D`. The gap between them is the duration. Nothing is parsed
/// from the output — the shell already knows.
public struct CommandEntry: Codable, Equatable, Sendable {
    /// The command line as typed, percent-decoded from the `C` mark.
    public var command: String
    /// The working directory when the command started (from the shell's `PWD`).
    public var directory: String
    /// The exit status, when the shell reported one.
    public var status: Int32?
    /// How long the command ran, in seconds.
    public var duration: Double
    /// When the command finished (Unix epoch, seconds).
    public var finishedAt: Date

    public init(command: String, directory: String, status: Int32?, duration: Double, finishedAt: Date) {
        self.command = command
        self.directory = directory
        self.status = status
        self.duration = duration
        self.finishedAt = finishedAt
    }
}

/// A timeline of finished commands, built from shell marks and persisted to disk.
///
/// The timeline is append-only: every command that finishes (and sends a `D` mark)
/// is added. There is no limit on history size; a background prune task can be
/// added later if it becomes a problem.
///
/// Persistence is a JSON file in the application support directory. The file is
/// rewritten on every addition, which is fine for the expected volume (hundreds
/// to a few thousand entries). If it grows, a compacting write or SQLite is the
/// next step.
public final class CommandTimeline {
    private let queue = DispatchQueue(label: "dev.nymbra.timeline", qos: .utility)
    private let fileURL: URL
    private var entries: [CommandEntry] = []
    private var pending: [TabID: PendingCommand] = [:]

    private struct PendingCommand {
        let command: String
        let directory: String
        let startedAt: Date
    }

    /// Create a timeline, loading existing history from `fileURL` if it exists.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.entries = Self.load(from: fileURL)
    }

    /// Load entries from disk. The file is a JSON array of `CommandEntry`.
    private static func load(from url: URL) -> [CommandEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([CommandEntry].self, from: data)) ?? []
    }

    /// Save all entries to disk. Called on the timeline's queue.
    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        // Atomic write: write to a temp file, then replace.
        let tempURL = fileURL.appendingPathExtension("tmp")
        _ = try? data.write(to: tempURL, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL,
                                                   backupItemName: nil, options: .usingNewMetadataOnly)
    }

    /// Feed a shell mark. Returns a finished entry if a command just completed.
    ///
    /// The marks come from the shell via the parser: `C` starts a command,
    /// `D` finishes it with an exit status. `A` and `B` are ignored.
    ///
    /// - Parameter mark: the shell mark
    /// - Parameter tabID: which tab the mark came from (for directory lookup)
    /// - Parameter getDirectory: a function that returns the current working
    ///   directory for `tabID`, or `nil` if unknown
    /// - Returns: the finished `CommandEntry`, or `nil` if no command completed
    public func feed(
        mark: ShellMark,
        tabID: TabID,
        getDirectory: @escaping (TabID) -> String?
    ) -> CommandEntry? {
        return queue.sync {
            switch mark {
            case .commandExecuted(let command):
                let dir = getDirectory(tabID) ?? ""
                let decoded = command ?? ""
                pending[tabID] = PendingCommand(command: decoded, directory: dir, startedAt: Date())
                return nil
            case .commandFinished(let status):
                let pendingCmd = pending.removeValue(forKey: tabID)
                guard let pendingCmd else { return nil } // D without a preceding C
                let finishedAt = Date()
                let duration = finishedAt.timeIntervalSince(pendingCmd.startedAt)
                let entry = CommandEntry(
                    command: pendingCmd.command,
                    directory: pendingCmd.directory,
                    status: status,
                    duration: duration,
                    finishedAt: finishedAt
                )
                entries.append(entry)
                save()
                return entry
            case .promptStart, .commandStart:
                return nil
            }
        }
    }

    /// All entries, most recent first.
    public func all() -> [CommandEntry] {
        queue.sync { entries.reversed() }
    }

    /// Entries matching a query (case-insensitive substring in command or directory).
    public func search(_ query: String) -> [CommandEntry] {
        guard !query.isEmpty else { return all() }
        let q = query.lowercased()
        return queue.sync {
            entries.reversed().filter { entry in
                entry.command.lowercased().contains(q) || entry.directory.lowercased().contains(q)
            }
        }
    }

    /// Entries filtered by exit status: `.succeeded` (0), `.failed` (non-zero),
    /// `.unknown` (no status reported), or `nil` for all.
    public func filter(status: StatusFilter?) -> [CommandEntry] {
        guard let status else { return all() }
        return queue.sync {
            entries.reversed().filter { entry in
                switch status {
                case .succeeded: return entry.status == 0
                case .failed: return entry.status != nil && entry.status != 0
                case .unknown: return entry.status == nil
                }
            }
        }
    }

    public enum StatusFilter: String, CaseIterable, Sendable {
        case succeeded, failed, unknown
    }

    /// Clear all history.
    public func clear() {
        queue.sync {
            entries.removeAll()
            save()
        }
    }
}