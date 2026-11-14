import Foundation

/// What a tab and a window are called, from what the terminal knows about the
/// shell in it.
///
/// A title is "where am I, and what is running": `nymbra`, `vim`, `api-server`.
/// Never the application's own name, which is the one thing the person already
/// knows. The rules are a pure function of facts so they can be asserted
/// without a window or a shell.
public enum TerminalTitle {

    /// What is known about one shell, at the moment of asking.
    public struct Facts: Equatable, Sendable {
        /// A name the person gave the tab. Always wins.
        public var customTitle: String?
        /// A title a program set with `OSC 0`/`OSC 2` — a prompt framework, an
        /// editor. Second, because the program asked for it on purpose.
        public var programTitle: String
        /// The program in the foreground, when it is not the shell (`vim`).
        public var foregroundProgram: String?
        /// The working directory, absolute.
        public var directory: String?
        /// The shell's executable path, for when nothing else is known.
        public var shellPath: String?
        /// The person's home directory, which is written `~`.
        public var home: String

        public init(customTitle: String? = nil,
                    programTitle: String = "",
                    foregroundProgram: String? = nil,
                    directory: String? = nil,
                    shellPath: String? = nil,
                    home: String = NSHomeDirectory()) {
            self.customTitle = customTitle
            self.programTitle = programTitle
            self.foregroundProgram = foregroundProgram
            self.directory = directory
            self.shellPath = shellPath
            self.home = home
        }
    }

    /// `/Users/me/src/nymbra` → `~/src/nymbra`; the home folder itself is `~`.
    public static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    /// The last component of a directory, as a tab name: `nymbra`, `~`, `/`.
    public static func folderName(_ path: String, home: String) -> String {
        let short = abbreviate(path, home: home)
        if short == "~" || short == "/" { return short }
        return (short as NSString).lastPathComponent
    }

    /// The tab's name. Custom title, then a program's title, then the running
    /// program, then the folder, then the shell.
    public static func tabName(_ facts: Facts) -> String {
        if let custom = facts.customTitle?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            return custom
        }
        if !facts.programTitle.isEmpty { return facts.programTitle }
        if let program = facts.foregroundProgram, !program.isEmpty { return program }
        if let directory = facts.directory { return folderName(directory, home: facts.home) }
        if let shell = facts.shellPath { return (shell as NSString).lastPathComponent }
        return "shell"
    }

    /// The window's title: the tab's name and, when it is not already the
    /// folder itself, where it is — `vim — ~/src/nymbra`. A title a program set
    /// is shown as it is: the program chose it.
    public static func windowTitle(_ facts: Facts) -> String {
        let name = tabName(facts)
        if let custom = facts.customTitle, !custom.isEmpty { return name }
        if !facts.programTitle.isEmpty { return name }
        guard let directory = facts.directory else { return name }
        let path = abbreviate(directory, home: facts.home)
        return name == path ? name : "\(name) \u{2014} \(path)"
    }

    /// The path as breadcrumb segments, home first: `~/src/nymbra` →
    /// `["~", "src", "nymbra"]`; `/usr/bin` → `["/", "usr", "bin"]`.
    public static func breadcrumbs(_ path: String, home: String) -> [String] {
        let short = abbreviate(path, home: home)
        if short == "~" || short == "/" { return [short] }
        if short.hasPrefix("~/") {
            return ["~"] + short.dropFirst(2).split(separator: "/").map(String.init)
        }
        return ["/"] + short.split(separator: "/").map(String.init)
    }
}
