import CoreGraphics
import ClipatoCore
import Foundation
import Observation

@Observable
final class LongScreenshotState {
    private(set) var images: [CGImage] = []
    private(set) var order: [Int] = []
    var joins: [LongScreenshotJoin] = []
    var analyses: [LongScreenshotAnalysis] = []
    var placements: [CollagePlacement] = []
    var canvasSize = CGSize.zero
    var selectedJoin: Int?
    var showsSelection = false
    var maximumOverlap = 10
    var zoom: CGFloat = 1
    var fitsWindow = true
    var focusRequest = 0
    var viewportResetRequest = 0
    var isWorking = false
    var hasStartedInitialStitch = false
    var error: String?
    var copied = false
    var alignmentMessage: String?
    var alignmentUndo: (joins: [LongScreenshotJoin], analyses: [LongScreenshotAnalysis])?
    @ObservationIgnored var workTask: Task<Void, Never>?
    @ObservationIgnored private var workID = UUID()

    var selectedImagePosition: Int? {
        showsSelection ? selectedJoin.map { $0 + 1 } ?? 0 : nil
    }

    func selectImage(at position: Int?) {
        showsSelection = position != nil
        selectedJoin = position.flatMap { $0 == 0 ? nil : $0 - 1 }
        focusRequest += 1
    }

    func reconcile(images sourceImages: [CGImage], order nextOrder: [Int]) {
        guard nextOrder != order else { return }
        cancelWork()
        let selectedSource = selectedImagePosition.map { order[$0] }
        let previousPositions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        var nextJoins: [LongScreenshotJoin] = []
        var nextAnalyses: [LongScreenshotAnalysis] = []
        if nextOrder.count > 1 {
            for position in 1..<nextOrder.count {
                if let previous = previousPositions[nextOrder[position - 1]],
                   previous + 1 < order.count, order[previous + 1] == nextOrder[position] {
                    nextJoins.append(joins[previous])
                    nextAnalyses.append(analyses[previous])
                } else {
                    nextJoins.append(LongScreenshotJoin(overlap: 0))
                    nextAnalyses.append(.noReliableMatch)
                }
            }
        }
        order = nextOrder
        images = nextOrder.map { sourceImages[$0] }
        joins = nextJoins
        analyses = nextAnalyses
        if let selectedSource { selectImage(at: nextOrder.firstIndex(of: selectedSource)) }
        copied = false
        alignmentMessage = nil
        alignmentUndo = nil
        do {
            let layout = try LongScreenshot.layout(images: images, joins: joins)
            placements = layout.placements
            canvasSize = layout.size
            error = nil
        } catch {
            placements = []
            canvasSize = .zero
            self.error = workspaceErrorDescription(error)
        }
    }

    func beginWork(initialStitch: Bool = false) -> UUID {
        if initialStitch { hasStartedInitialStitch = true }
        workID = UUID()
        isWorking = true
        return workID
    }

    func finishWork(_ id: UUID) {
        guard id == workID else { return }
        isWorking = false
        workTask = nil
    }

    func cancelWork() {
        workID = UUID()
        workTask?.cancel()
        workTask = nil
        isWorking = false
    }
}
