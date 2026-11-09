/// Proportional scrolling for two documents whose lengths and viewport sizes can differ.
/// Offsets are measured from the top; layout changes preserve the last reading progress.
public struct ScrollSynchronization: Sendable {
    public enum Pane: Sendable { case source, translation }

    public struct Metrics: Equatable, Sendable {
        public var offset: Double
        public var contentHeight: Double
        public var viewportHeight: Double

        public init(offset: Double, contentHeight: Double, viewportHeight: Double) {
            self.offset = offset
            self.contentHeight = contentHeight
            self.viewportHeight = viewportHeight
        }

        public var scrollableHeight: Double { max(0, contentHeight - viewportHeight) }
        public var progress: Double {
            scrollableHeight > 0 ? min(1, max(0, offset / scrollableHeight)) : 0
        }
    }

    public private(set) var isEnabled = false
    public private(set) var progress: Double = 0
    public private(set) var leader: Pane = .source
    private var metrics: [Pane: Metrics] = [:]

    public init() {}

    public mutating func setEnabled(_ enabled: Bool) -> [Pane: Double] {
        guard enabled != isEnabled else { return [:] }
        isEnabled = enabled
        if enabled { progress = metrics[leader]?.progress ?? 0 }
        return destinations()
    }

    /// Programmatic movements must be recorded without making the follower the leader.
    public mutating func update(_ new: Metrics, for pane: Pane, programmatic: Bool = false) -> [Pane: Double] {
        let previous = metrics.updateValue(new, forKey: pane)
        guard !programmatic else { return [:] }
        guard let previous else { return destinations() }
        if previous.contentHeight != new.contentHeight || previous.viewportHeight != new.viewportHeight {
            return destinations()
        }
        guard abs(previous.offset - new.offset) > 0.5, new.scrollableHeight > 0 else { return [:] }
        leader = pane
        progress = new.progress
        return destinations(excluding: pane)
    }

    public mutating func remove(_ pane: Pane) { metrics[pane] = nil }

    public mutating func reset() -> [Pane: Double] {
        progress = 0
        leader = .source
        // New documents start at the top even when scrolling is not linked.
        return metrics.mapValues { _ in 0 }
    }

    private func destinations(excluding pane: Pane? = nil) -> [Pane: Double] {
        guard isEnabled else { return [:] }
        return metrics.filter { $0.key != pane }.mapValues { progress * $0.scrollableHeight }
    }
}
