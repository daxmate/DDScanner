// 开发用「去畸变自测页」——今晚拿真机看数字的页面（仅 DEBUG；步骤见 docs/device-test-uvdoc.md）。
//
// 只读 Environment（依赖由组合根装配）：模型不可用时**优雅降级**为一行原因，不崩、不留白屏。
#if DEBUG
    import DDScannerCore
    import DDScannerDewarp
    import SwiftUI

    struct DewarpSelfTestView: View {
        @Environment(\.scanEnvironment) private var scanEnvironment
        @State private var report: DewarpSelfTestReport?
        @State private var failure: String?
        @State private var isRunning = false

        /// 推理次数（自测页固定 30 次，取 min/median/max）。
        private let iterations = 30

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusBlock
                    if let report {
                        metricsBlock(report)
                        previewBlock(report)
                    } else if let failure {
                        failureBlock(failure)
                    } else {
                        runningBlock
                    }
                    footnote
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("去畸变自测")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("重跑") { run() }
                        .disabled(isRunning)
                }
            }
            .task {
                if report == nil, failure == nil { run() }
            }
        }

        // MARK: 各区块

        private var statusBlock: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("模型状态").font(.headline)
                Text(scanEnvironment?.dewarpStatus ?? "Environment 未注入")
                    .font(.footnote)
                    .foregroundStyle(scanEnvironment?.gridPredictor == nil ? .red : .secondary)
            }
        }

        private func metricsBlock(_ report: DewarpSelfTestReport) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("实测数字").font(.headline)
                row("设备 / 系统", report.device)
                row("算力（MLComputeUnits）", report.computeUnits)
                row("输入尺寸", report.inputSize)
                row("输出网格", report.gridSize)
                row("推理次数", "\(report.iterations)")
                row("推理 min / median / max", String(
                    format: "%.2f / %.2f / %.2f ms",
                    report.inferenceMinimumMilliseconds,
                    report.inferenceMedianMilliseconds,
                    report.inferenceMaximumMilliseconds
                ))
                row("单次均耗时（含首跑）", String(format: "%.2f ms", report.inferenceTotalMilliseconds / Double(report.iterations)))
                row("预处理（缩放到输入）", String(format: "%.2f ms", report.preprocessMilliseconds))
                row("全分辨率重采样", String(format: "%.2f ms", report.resampleMilliseconds))
            }
            .font(.footnote)
        }

        private func previewBlock(_ report: DewarpSelfTestReport) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("校正前后对比（左：原图，右：重采样）").font(.headline)
                HStack(alignment: .top, spacing: 8) {
                    Image(uiImage: report.originalImage).resizable().scaledToFit()
                        .border(Color.secondary.opacity(0.4))
                    Image(uiImage: report.dewarpedImage).resizable().scaledToFit()
                        .border(Color.secondary.opacity(0.4))
                }
            }
        }

        private func failureBlock(_ message: String) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("未能完成自测").font(.headline).foregroundStyle(.red)
                Text(message).font(.footnote)
            }
        }

        private var runningBlock: some View {
            HStack(spacing: 8) {
                ProgressView()
                Text("正在跑 \(iterations) 次推理…").font(.footnote)
            }
        }

        private var footnote: some View {
            Text("仅 DEBUG 构建包含本页。Mac 上的 2.28 ms 只是指示值，真机数字以本页为准。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        private func row(_ title: String, _ value: String) -> some View {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value).multilineTextAlignment(.trailing)
            }
        }

        // MARK: 执行

        private func run() {
            guard let environment = scanEnvironment else {
                failure = "Environment 未注入（组合根未装配）"
                return
            }
            guard let predictor = environment.gridPredictor else {
                // 优雅降级：模型不可用只显示原因，页面照常可用。
                report = nil
                failure = environment.dewarpStatus
                return
            }
            isRunning = true
            failure = nil
            do {
                report = try DewarpSelfTestRunner.run(
                    predictor: predictor,
                    descriptor: .uvDoc,
                    modelStatus: environment.dewarpStatus,
                    computeUnits: environment.dewarpComputeUnits,
                    iterations: iterations
                )
            } catch {
                report = nil
                failure = "\(error)"
            }
            isRunning = false
        }
    }
#endif
