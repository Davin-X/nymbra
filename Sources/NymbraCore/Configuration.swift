import Foundation

/// The user's settings, as plain data.
///
/// Loading is deliberately **total**: every field has a default, a missing key
/// is not an error, and a value of the wrong type falls back rather than
/// throwing. A terminal is the tool people reach for when something else is
/// already broken, so it must never refuse to start because of its own
/// configuration file.
///
/// The model lives here, in the UI-free core, so settings can be asserted
/// without a window. See `docs/adr/0006-configuration-as-a-validated-json-file.md`.
public struct Configuration: Codable, Equatable, Sendable {

    public var appearance: Appearance
    public var colours: Colours
    public var behaviour: Behaviour
    public var keyboard: KeyBindings
    public var shell: Shell

    public init() {
        appearance = Appearance()
        colours = Colours()
        behaviour = Behaviour()
        keyboard = KeyBindings()
        shell = Shell()
    }

    // MARK: - Sections

    /// Font, and the size the grid is measured from.
    public struct Appearance: Codable, Equatable, Sendable {
        public static let defaultFontFamily = "Menlo"
        public static let defaultFontSize = 13.0
        public static let fontSizeRange = 6.0...72.0

        public var fontFamily: String = defaultFontFamily
        public var fontSize: Double = defaultFontSize

        public init() {}

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fontFamily = container.orDefault(.fontFamily, Appearance.defaultFontFamily)
            fontSize = container.orDefault(.fontSize, Appearance.defaultFontSize)
        }
    }

    /// What the user picked. `preset` is the "theme": one name, plus per-colour
    /// overrides for people who want to adjust one thing.
    public struct Colours: Codable, Equatable, Sendable {

        public enum Preset: String, Codable, CaseIterable, Sendable {
            case dark, light, highContrast
        }

        /// The colours a user may override by name, including the ones that are
        /// not part of the 16 ANSI colours.
        public static let names: Set<String> = [
            "foreground", "background", "cursor", "selection",
            "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
            "bright-black", "bright-red", "bright-green", "bright-yellow",
            "bright-blue", "bright-magenta", "bright-cyan", "bright-white",
        ]

        public var preset: Preset = .dark

        /// Per-colour overrides keyed by a name from `names`, valued `#rrggbb`.
        /// A name we do not know, or a value that is not a colour, is dropped on
        /// load with a warning rather than failing it.
        public var overrides: [String: String] = [:]

        public init() {}

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            preset = container.orDefault(.preset, Preset.dark)
            overrides = container.orDefault(.overrides, [:])
        }

        /// `#rrggbb`, or `nil`. Parsed here rather than in the view, so an
        /// invalid colour is caught when settings load instead of when drawn.
        public static func rgb(from text: String) -> (red: UInt8, green: UInt8, blue: UInt8)? {
            guard text.count == 7, text.hasPrefix("#") else { return nil }
            let digits = text.dropFirst()
            guard digits.allSatisfy({ $0.isHexDigit }), let value = UInt32(digits, radix: 16) else {
                return nil
            }
            return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
        }
    }

    /// How the terminal behaves while in use.
    public struct Behaviour: Codable, Equatable, Sendable {

        public enum CursorShape: String, Codable, CaseIterable, Sendable {
            case block, bar, underline
        }

        public static let defaultScrollbackLines = 10_000
        public static let scrollbackRange = 0...1_000_000

        public var cursorShape: CursorShape = .block
        public var cursorBlinks = true
        public var scrollbackLines = defaultScrollbackLines

        /// Ask before closing a window whose program is still running. On by
        /// default: losing a running build to a stray Cmd+W is unforgivable.
        public var confirmBeforeClosingRunningSession = true

        public init() {}

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cursorShape = container.orDefault(.cursorShape, CursorShape.block)
            cursorBlinks = container.orDefault(.cursorBlinks, true)
            scrollbackLines = container.orDefault(.scrollbackLines, Behaviour.defaultScrollbackLines)
            confirmBeforeClosingRunningSession =
                container.orDefault(.confirmBeforeClosingRunningSession, true)
        }
    }

    /// Shortcut overrides. Commands keep their defaults unless overridden, so a
    /// config file only ever has to mention what the user changed.
    public struct KeyBindings: Codable, Equatable, Sendable {
        /// Command name to shortcut, e.g. `"paste": "cmd+v"`. The syntax is
        /// `NymbraInput`'s; an entry that is not a shortcut is dropped on load.
        public var overrides: [String: String] = [:]

        public init() {}

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            overrides = container.orDefault(.overrides, [:])
        }
    }

    /// Which shell to run.
    public struct Shell: Codable, Equatable, Sendable {
        /// Absolute path, or `nil` for the user's `$SHELL`. `nil` is the
        /// default: hardcoding `/bin/zsh` would be wrong on a machine where the
        /// user deliberately chose something else.
        public var path: String?

        public init() {}

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = (try? container.decodeIfPresent(String.self, forKey: .path)) ?? nil
        }
    }

    // MARK: - Decoding

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appearance = container.orDefault(.appearance, Appearance())
        colours = container.orDefault(.colours, Colours())
        behaviour = container.orDefault(.behaviour, Behaviour())
        keyboard = container.orDefault(.keyboard, KeyBindings())
        shell = container.orDefault(.shell, Shell())
    }

    /// The top-level keys this version understands. Anything else is reported
    /// and ignored, so a config written by a newer Nymbra does not break an
    /// older one.
    public static let knownKeys: Set<String> = [
        "appearance", "colours", "behaviour", "keyboard", "shell",
    ]

    /// A configuration together with anything that had to be repaired or
    /// ignored while reading it. The caller shows these; it never throws.
    public struct LoadResult: Sendable {
        public let configuration: Configuration
        public let warnings: [String]

        public var isClean: Bool { warnings.isEmpty }

        public init(configuration: Configuration, warnings: [String]) {
            self.configuration = configuration
            self.warnings = warnings
        }
    }

    // MARK: - Location

    /// `~/Library/Application Support/Nymbra/config.json`, or `$NYMBRA_CONFIG`
    /// when set. The environment override exists so tests and CI can exercise
    /// the real file path without touching the user's own settings.
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["NYMBRA_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Nymbra/config.json")
    }

    // MARK: - Loading and saving

    /// Read the configuration. Never throws and never returns nothing: a missing
    /// file is the defaults, and a broken file is the defaults plus a warning.
    public static func load(from url: URL? = nil) -> LoadResult {
        let url = url ?? defaultURL

        guard let data = try? Data(contentsOf: url) else {
            return LoadResult(configuration: Configuration(), warnings: [])
        }

        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return LoadResult(
                configuration: Configuration(),
                warnings: ["\(url.lastPathComponent) is not a JSON object; using the defaults"]
            )
        }

        var warnings: [String] = []
        for key in object.keys.sorted() where !knownKeys.contains(key) {
            warnings.append("ignoring unknown setting \"\(key)\"")
        }

        // The permissive decoder below cannot fail for a JSON object, so no
        // `try` can reach the caller.
        var configuration = (try? JSONDecoder().decode(Configuration.self, from: data))
            ?? Configuration()
        warnings += configuration.normalise()

        return LoadResult(configuration: configuration, warnings: warnings)
    }

    /// Repair values that are out of range or meaningless, reporting each
    /// repair. Called on load, and safe to call again after a programmatic
    /// change.
    @discardableResult
    public mutating func normalise() -> [String] {
        var warnings: [String] = []

        let range = Appearance.fontSizeRange
        if !range.contains(appearance.fontSize) {
            let clamped = min(max(appearance.fontSize, range.lowerBound), range.upperBound)
            warnings.append("font size \(appearance.fontSize)pt is outside \(range.lowerBound)–\(range.upperBound)pt; using \(clamped)pt")
            appearance.fontSize = clamped
        }

        if appearance.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append("font family is empty; using \(Appearance.defaultFontFamily)")
            appearance.fontFamily = Appearance.defaultFontFamily
        }

        let scrollback = Behaviour.scrollbackRange
        if !scrollback.contains(behaviour.scrollbackLines) {
            let clamped = min(max(behaviour.scrollbackLines, scrollback.lowerBound), scrollback.upperBound)
            warnings.append("scrollback of \(behaviour.scrollbackLines) lines is outside \(scrollback.lowerBound)–\(scrollback.upperBound); using \(clamped)")
            behaviour.scrollbackLines = clamped
        }

        for name in colours.overrides.keys.sorted() {
            let value = colours.overrides[name] ?? ""
            if !Colours.names.contains(name) {
                warnings.append("ignoring colour override \"\(name)\": not a colour this terminal knows")
            } else if Colours.rgb(from: value) == nil {
                warnings.append("ignoring colour override \"\(name)\": \"\(value)\" is not #rrggbb")
            }
        }
        colours.overrides = colours.overrides.filter {
            Colours.names.contains($0.key) && Colours.rgb(from: $0.value) != nil
        }

        for command in keyboard.overrides.keys.sorted() {
            let shortcut = keyboard.overrides[command] ?? ""
            let trimmed = shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.contains(" ") {
                warnings.append("ignoring shortcut for \"\(command)\": \"\(shortcut)\" is not a shortcut")
            }
        }
        keyboard.overrides = keyboard.overrides.filter {
            let trimmed = $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !trimmed.contains(" ")
        }

        if let path = shell.path, !path.hasPrefix("/") {
            warnings.append("shell \"\(path)\" is not an absolute path; using $SHELL")
            shell.path = nil
        }

        return warnings
    }

    /// True when nothing in the configuration is out of range. Loading always
    /// returns a configuration that satisfies this; the settings window uses it
    /// to decide whether a change needs repairing.
    public var isNormalised: Bool {
        var copy = self
        return copy.normalise().isEmpty
    }

    /// Write the configuration out. Pretty-printed with sorted keys, so a diff
    /// of two configs is readable by a person.
    public func save(to url: URL? = nil) throws {
        let url = url ?? Configuration.defaultURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(self)
        data.append(0x0A)  // a trailing newline, because it is a text file
        try data.write(to: url, options: .atomic)
    }

    /// Restore the defaults, writing them out so the result is on disk and
    /// visible rather than merely in memory.
    public static func reset(at url: URL? = nil) throws {
        try Configuration().save(to: url)
    }
}

// MARK: - Decoding that cannot fail

private extension KeyedDecodingContainer {
    /// A value that falls back instead of throwing. A missing key, or one of the
    /// wrong type, is not worth refusing to start over.
    func orDefault<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }
}
