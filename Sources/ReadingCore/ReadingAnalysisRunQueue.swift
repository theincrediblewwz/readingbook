import Foundation

/// A transient index for one frozen run. Completion is supplied only after the
/// caller has checked the current canonical snapshot; a successful request or a
/// partial/receipt publication is not itself completion. This never owns a book.
/// Building costs O(K + B); ready operations cost O(log K). Completion frontiers
/// and barrier watchers each advance once per monotone epoch, O(K + B) in total.
public struct ReadingAnalysisRunQueue: Sendable {
    private struct Barrier: Sendable {
        var members: [Int] = []
        var firstIncomplete = 0
        var watchers: [Int] = []
        var nextWatcher = 0
    }

    private let chunks: [ReadingAnalysisChunk]
    private let indices: [String: Int]
    private var runningAliases: [String: Int]
    private var aliasedRunningIndices: Set<Int>
    private let unitIndices: [String: Int]
    private let memberships: [[Int]]
    private var barriers: [Barrier]
    private var completed: [Bool]
    private var running: [Bool]
    private var pending: [Int]
    private var ready: ReadingReadyIndex
    public private(set) var completedCount: Int
    public private(set) var runningCount: Int
    public private(set) var dispatchCount: Int
    public var count: Int { chunks.count }
    public var scheduledChunks: [ReadingAnalysisChunk] { chunks }

    func runningChunk(_ id: String) -> ReadingAnalysisChunk? {
        guard let index = indices[id] ?? runningAliases[id], running[index] else { return nil }
        return chunks[index]
    }

    public init(chunks: [ReadingAnalysisChunk], steps: [ReadingExecutionStep], chapters: [String: String],
                completed: Set<String>, running: Set<String> = [], dispatchCount: Int = 0,
                runningAliases: [String: String] = [:]) throws {
        var indices: [String: Int] = [:], unitIndices: [String: Int] = [:]
        var chapterBarriers: [String: Int] = [:]
        var barriers = [Barrier()]
        var memberships = [[Int]](repeating: [], count: chunks.count)
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            guard indices.updateValue(index, forKey: chunk.id) == nil else { throw ReadingError.invalid("分析块标识重复，未安排任务。") }
            barriers[0].members.append(index)
            memberships[index].append(0)
            var own = Set<String>()
            for id in chunk.unitIDs {
                if unitIndices[id] == nil { unitIndices[id] = index }
                let chapter = chunk.chapterID ?? chapters[id] ?? ""
                guard own.insert(chapter).inserted else { continue }
                let barrier: Int
                if let found = chapterBarriers[chapter] { barrier = found }
                else { barrier = barriers.count; chapterBarriers[chapter] = barrier; barriers.append(Barrier()) }
                barriers[barrier].members.append(index)
                memberships[index].append(barrier)
            }
        }
        var scopeBarriers: [Int: Int] = [:]
        for (index, chunk) in chunks.enumerated() {
            guard let job = chunk.scopeJob else { continue }
            let members = job.dependencyIDs.compactMap { indices[$0] }
            guard !members.isEmpty, members.count == job.dependencyIDs.count,
                  Set(members).count == members.count, members.allSatisfy({ $0 < index }) else {
                throw ReadingError.invalid("范围回顾的依赖清单不完整或顺序无效，未安排请求。")
            }
            let barrier = barriers.count
            barriers.append(Barrier(members: members.sorted()))
            scopeBarriers[index] = barrier
            for member in members { memberships[member].append(barrier) }
        }
        var aliasIndices: [String: Int] = [:], aliasedIndices = Set<Int>()
        for (old, current) in runningAliases {
            guard running.contains(old), indices[old] == nil, let index = indices[current],
                  !running.contains(current), aliasedIndices.insert(index).inserted else {
                throw ReadingError.invalid("进行中的分析块身份无法唯一对应，已保存内容保留。")
            }
            aliasIndices[old] = index
        }
        let completeBits = chunks.map { completed.contains($0.id) }
        let runningBits = chunks.enumerated().map { running.contains($0.element.id) || aliasedIndices.contains($0.offset) }
        for id in barriers.indices {
            try Task.checkCancellation()
            while barriers[id].firstIncomplete < barriers[id].members.count,
                  completeBits[barriers[id].members[barriers[id].firstIncomplete]] {
                barriers[id].firstIncomplete += 1
            }
        }
        let frequencies = Dictionary(steps.map { ($0.id, $0.frequency) }, uniquingKeysWith: { _, last in last })
        var pending = [Int](repeating: 0, count: chunks.count)
        for (index, chunk) in chunks.enumerated() where !completeBits[index] {
            try Task.checkCancellation()
            let actions = Set(chunk.stepIDs.compactMap { frequencies[$0] })
            var required: [Int] = actions.contains(.book) ? [0] : []
            if let barrier = scopeBarriers[index] { required.append(barrier) }
            if actions.contains(.chapter) {
                // Match the original scheduler exactly: missing own chapters
                // are omitted, but a missing prior chapter belongs to "".
                for chapter in chunk.chapterID.map({ Set([$0]) }) ?? Set(chunk.unitIDs.compactMap { chapters[$0] }) {
                    if let barrier = chapterBarriers[chapter] { required.append(barrier) }
                }
            }
            for id in required {
                let position = barriers[id].firstIncomplete
                let frontier = position < barriers[id].members.count ? barriers[id].members[position] : chunks.count
                if frontier < index {
                    pending[index] += 1
                    barriers[id].watchers.append(index)
                }
            }
        }
        self.chunks = chunks; self.indices = indices; self.runningAliases = aliasIndices; self.aliasedRunningIndices = aliasedIndices
        self.unitIndices = unitIndices
        self.memberships = memberships; self.barriers = barriers
        self.completed = completeBits; self.running = runningBits; self.pending = pending
        self.ready = ReadingReadyIndex(completeBits.indices.map { !completeBits[$0] && !runningBits[$0] && pending[$0] == 0 })
        self.completedCount = completeBits.reduce(0) { $0 + ($1 ? 1 : 0) }
        self.runningCount = runningBits.reduce(0) { $0 + ($1 ? 1 : 0) }
        self.dispatchCount = dispatchCount
        try Task.checkCancellation()
    }

    public func next(currentUnitID: String?) -> ReadingAnalysisChunk? {
        guard let oldest = ready.first else { return nil }
        if dispatchCount % 4 == 3 { return chunks[oldest] }
        guard let currentUnitID, let target = unitIndices[currentUnitID], let index = ready.nearest(to: target) else { return chunks[oldest] }
        return chunks[index]
    }

    /// Choosing and starting are separate so a caller can keep the same atomic
    /// main-actor admission boundary as its task-group bookkeeping.
    @discardableResult public mutating func begin(_ id: String) -> Bool {
        guard let index = indices[id], !completed[index], !running[index], pending[index] == 0 else { return false }
        running[index] = true; runningCount += 1; ready.set(index, false)
        dispatchCount = dispatchCount == Int.max ? 0 : dispatchCount + 1
        return true
    }

    /// A receipt-only success, partial result or bounded retry returns an
    /// incomplete job to ready. The caller commits receipt results before it
    /// admits another job. Completion never follows from this method.
    public mutating func finish(_ id: String) {
        // An identity-only queue recovery may leave an old worker in flight.
        // Its alias reserves the equivalent job and is consumed exactly once.
        let target: Int?
        if let index = indices[id] {
            guard !aliasedRunningIndices.contains(index) else { return }
            target = index
        } else {
            target = runningAliases.removeValue(forKey: id)
            if let target { aliasedRunningIndices.remove(target) }
        }
        guard let index = target, running[index] else { return }
        running[index] = false; runningCount -= 1
        if !completed[index] && pending[index] == 0 { ready.set(index, true) }
    }

    public func isComplete(_ id: String) -> Bool { indices[id].map { completed[$0] } ?? false }

    /// Monotone within a checked canonical epoch. A checkpoint removal requires
    /// a fresh queue, because chapter/book barriers may become blocked again.
    public mutating func markComplete(_ id: String) {
        guard let index = indices[id], !completed[index] else { return }
        completed[index] = true; completedCount += 1; ready.set(index, false)
        // Running still owns its slot until its task-group result is dequeued.
        for barrierID in memberships[index] {
            while barriers[barrierID].firstIncomplete < barriers[barrierID].members.count,
                  completed[barriers[barrierID].members[barriers[barrierID].firstIncomplete]] {
                barriers[barrierID].firstIncomplete += 1
            }
            let position = barriers[barrierID].firstIncomplete
            let frontier = position < barriers[barrierID].members.count ? barriers[barrierID].members[position] : chunks.count
            while barriers[barrierID].nextWatcher < barriers[barrierID].watchers.count,
                  barriers[barrierID].watchers[barriers[barrierID].nextWatcher] <= frontier {
                let released = barriers[barrierID].watchers[barriers[barrierID].nextWatcher]
                barriers[barrierID].nextWatcher += 1; pending[released] -= 1
                if pending[released] == 0 && !completed[released] && !running[released] { ready.set(released, true) }
            }
        }
    }
}

/// A fixed-size Fenwick index avoids linear sorted-array insertion/removal.
/// It supports oldest and predecessor/successor selection in O(log K).
private struct ReadingReadyIndex: Sendable {
    private var bits: [Bool]
    private var tree: [Int]
    private var count: Int
    init(_ bits: [Bool]) {
        self.bits = bits; self.tree = [Int](repeating: 0, count: bits.count + 1)
        self.count = 0
        for index in bits.indices {
            let position = index + 1
            if bits[index] { count += 1 }
            tree[position] += bits[index] ? 1 : 0
            let parent = position + (position & -position)
            if parent < tree.count { tree[parent] += tree[position] }
        }
    }
    mutating func set(_ index: Int, _ value: Bool) {
        guard bits[index] != value else { return }
        bits[index] = value
        let delta = value ? 1 : -1; count += delta
        var position = index + 1
        while position < tree.count { tree[position] += delta; position += position & -position }
    }
    var first: Int? { count == 0 ? nil : select(1) }
    func nearest(to target: Int) -> Int? {
        guard count > 0 else { return nil }
        let before = prefix(target), through = prefix(target + 1)
        let left = through > 0 ? select(through) : nil
        let right = before < count ? select(before + 1) : nil
        guard let left else { return right }
        guard let right else { return left }
        return target - left < right - target ? left : right
    }
    private func prefix(_ length: Int) -> Int {
        var position = length, sum = 0
        while position > 0 { sum += tree[position]; position -= position & -position }
        return sum
    }
    private func select(_ rank: Int) -> Int {
        var step = 1, position = 0, remaining = rank
        while step <= bits.count / 2 { step <<= 1 }
        while step > 0 {
            let next = position + step
            if next < tree.count && tree[next] < remaining { position = next; remaining -= tree[next] }
            step >>= 1
        }
        return position
    }
}
