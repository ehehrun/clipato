import CoreMedia

/// Host-clock segments keep every output format on the same active recording timeline.
struct RecordingTimeline {
    private var segmentStarted: CMTime?
    private var recorded = CMTime.zero
    private var hasResumed = false

    init(started: CMTime) {
        segmentStarted = started
    }

    var isPaused: Bool { segmentStarted == nil }

    func elapsed(at hostTime: CMTime) -> CMTime {
        guard let segmentStarted else { return recorded }
        return recorded + CMTimeMaximum(.zero, hostTime - segmentStarted)
    }

    mutating func pause(at hostTime: CMTime) {
        guard segmentStarted != nil else { return }
        recorded = elapsed(at: hostTime)
        segmentStarted = nil
    }

    mutating func resume(at hostTime: CMTime) {
        guard segmentStarted == nil else { return }
        segmentStarted = hostTime
        hasResumed = true
    }

    func frameTime(at hostTime: CMTime, initialSnapshot: Bool = false) -> CMTime? {
        guard let segmentStarted else { return nil }
        // A newly created stream can report an older display time for its initial snapshot.
        // Only that stream's first snapshot may cross a resume boundary.
        guard !hasResumed || initialSnapshot || hostTime >= segmentStarted else { return nil }
        return recorded + CMTimeMaximum(.zero, hostTime - segmentStarted)
    }
}
