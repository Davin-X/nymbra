import Foundation

/// Something in a terminal that needs a person's attention.
///
/// These are the few things worth surfacing when they happen out of sight — a
/// command that failed, a long command that finished — collected into a short,
/// local list rather than a stream of notifications. The list is bounded on
/// purpose: a firehose is not attention, it is noise.
///
/// The model is UI-free so the rules (what stays, what is replaced, what is
/// cleared) can be asserted without a window.
public struct AttentionItem: Equatable, Sendable, Identifiable {
    public let id: UUID
    /// An opaque key for where this happened (for example, a tab). The app uses
    /// it to focus the right place; the model only compares it.
    public var targetKey: String
    public var title: String
    public var body: String
    public var isFailure: Bool
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        targetKey: String,
        title: String,
        body: String,
        isFailure: Bool,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.targetKey = targetKey
        self.title = title
        self.body = body
        self.isFailure = isFailure
        self.timestamp = timestamp
    }

    /// The inbox entry for an announcement about `targetKey`.
    ///
    /// The same announcement that decides whether a notification is posted
    /// decides whether the inbox hears about it, so the two cannot disagree:
    /// nothing is ever in the inbox that was too short, or watched, to announce.
    public init(_ announcement: CommandAttention.Announcement,
                targetKey: String,
                timestamp: Date = Date()) {
        self.init(targetKey: targetKey,
                  title: announcement.title,
                  body: announcement.body,
                  isFailure: announcement.isFailure,
                  timestamp: timestamp)
    }

    /// How long ago this happened, at a glance: "just now", "4m ago", "2h ago",
    /// "3d ago". Coarse on purpose — the list is for "which tab", not "when".
    public func age(now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(timestamp))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}

/// A bounded, most-recent-first list of things that need attention.
///
/// Adding an item for a target that already has one replaces the older item for
/// that target, so the list says "this tab needs you" once, with its latest
/// state, rather than repeating itself. The whole list is capped at `limit`.
public struct AttentionInbox: Sendable, Equatable {
    public private(set) var items: [AttentionItem] = []
    public var limit: Int

    public init(limit: Int = 3) {
        self.limit = max(1, limit)
    }

    /// Record something that needs attention. Replaces any existing item for the
    /// same `targetKey`, moves it to the front, and trims to `limit`.
    public mutating func add(_ item: AttentionItem) {
        items.removeAll { $0.targetKey == item.targetKey }
        items.insert(item, at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
    }

    /// Drop whatever was recorded for `targetKey` (for example, because the
    /// person is now looking at it).
    public mutating func remove(targetKey: String) {
        items.removeAll { $0.targetKey == targetKey }
    }

    public mutating func clear() {
        items.removeAll()
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }
}
