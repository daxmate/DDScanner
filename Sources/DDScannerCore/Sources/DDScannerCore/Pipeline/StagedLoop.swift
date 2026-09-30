// StagedLoop —— 长耗时循环的「可取消 + 可回报进度」契约（纯逻辑，平台无关）。
//
// 为什么要有它：自测页最重的一段是「30 次推理 + 全分辨率重采样」，旧实现把整条管线跑在主线程上，
// 界面被无声占住数秒到十几秒（真机被系统看门狗杀掉）。把「每轮前检查取消、每轮后回报进度」这句
// 话收成一个纯函数，就能在本机 `swift test` 里守住两条契约：
//   ① 进度必须逐轮回报（UI 才有 n/N 可看）；
//   ② 取消后**立即停止**且不再回报过期进度（不能让过期结果回填界面）。
import Foundation

/// 可取消的分阶段循环。
public enum StagedLoop {
    /// 逐轮执行 `body`；每轮前检查取消（`shouldCancel`），每轮后回报进度。
    ///
    /// - Parameters:
    ///   - iterations: 轮数（≤ 0 时只做一次取消检查）。
    ///   - shouldCancel: 取消判据；默认读当前 `Task` 的取消状态（后台任务被 `cancel()` 后即为真）。
    ///   - onProgress: 进度回报 `(已完成, 总数)`；开始时先报 `(0, total)`，便于 UI 立刻显示 n/N。
    ///   - body: 单轮工作，`index` 从 0 开始。
    /// - Throws: `CancellationError`（取消）；`body` 自身抛出的错误原样上抛。
    public static func run(
        iterations: Int,
        shouldCancel: () -> Bool = { Task.isCancelled },
        onProgress: (_ completed: Int, _ total: Int) -> Void = { _, _ in },
        body: (Int) throws -> Void
    ) throws {
        let total = max(iterations, 0)
        onProgress(0, total)
        for index in 0 ..< total {
            if shouldCancel() { throw CancellationError() }
            try body(index)
            if shouldCancel() { throw CancellationError() }
            onProgress(index + 1, total)
        }
    }
}
