// StagedLoop 契约测试：进度逐轮回报、取消立即生效且不再回报过期进度。
import Foundation
import Testing
@testable import DDScannerCore

@Suite("StagedLoop（可取消 + 进度）")
struct StagedLoopTests {
    @Test("逐轮回报进度（含起始 0/total），body 调用次数正确")
    func reportsProgressEveryIteration() throws {
        var progress = [(Int, Int)]()
        var calls = 0
        try StagedLoop.run(iterations: 3, onProgress: { completed, total in
            progress.append((completed, total))
        }, body: { _ in
            calls += 1
        })
        #expect(calls == 3)
        #expect(progress.map(\.0) == [0, 1, 2, 3])
        #expect(progress.allSatisfy { $0.1 == 3 })
    }

    @Test("0 轮：只回报一次 (0,0)，不调用 body")
    func zeroIterations() throws {
        var progress = [(Int, Int)]()
        var calls = 0
        try StagedLoop.run(iterations: 0, onProgress: { progress.append(($0, $1)) }, body: { _ in calls += 1 })
        #expect(calls == 0)
        #expect(progress.count == 1 && progress[0] == (0, 0))
    }

    @Test("取消判据为真 → 抛 CancellationError，且不再回报后续进度")
    func cancellationStopsImmediately() {
        var progress = [Int]()
        var calls = 0
        var completed = 0
        #expect(throws: CancellationError.self) {
            try StagedLoop.run(
                iterations: 10,
                shouldCancel: { completed >= 2 },
                onProgress: { done, _ in
                    progress.append(done)
                    completed = done
                },
                body: { _ in calls += 1 }
            )
        }
        #expect(calls == 2, "取消后不得继续执行 body")
        #expect(progress == [0, 1, 2], "取消后不得回报过期进度")
    }

    @Test("真实 Task 取消：后台任务被 cancel() 后抛 CancellationError")
    func realTaskCancellation() async {
        let task = Task { () -> Int in
            var calls = 0
            try StagedLoop.run(iterations: 1_000_000) { _ in
                calls += 1
                if calls == 5 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return calls
        }
        let outcome = await task.result
        #expect((try? outcome.get()) == nil, "取消后应抛错而不是正常返回")
    }

    @Test("body 抛错原样上抛，且不吞掉")
    func bodyErrorPropagates() {
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try StagedLoop.run(iterations: 3, body: { index in
                if index == 1 { throw Boom() }
            })
        }
    }
}
