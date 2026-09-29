// CoreMLDewarpBackend —— Core ML 去畸变后端：装载 UVDoc 网格模型并推理。
//
// 契约（`GridPredicting`）：输入整幅像素（`FloatImage`，RGB，Float32 ∈ [0,1]）→
// 输出归一化采样网格（`NormalizedSampleGrid`）。**不**在模型里做重采样：网格坐标为
// 归一化坐标，重采样由 `DDScannerCore.GridResampler` 以 Float32 完成（见
// `Tools/ModelConvert/README.md` 的精度依据）。
//
// 降级：模型缺失 / 装载失败 / 输入尺寸不符一律**抛错**，绝不崩；组合根用 `try?` 装配，
// 拿不到模型就把 `gridPredictor` 置空（见 `App/AppCompositionRoot.swift`）。
import CoreML
import DDScannerCore
import Foundation

public struct CoreMLDewarpBackend: @unchecked Sendable, GridPredicting {
    public let descriptor: DewarpModelDescriptor
    /// 请求的算力单元；真机自测页会把它显示出来（便于判断是否走了 ANE）。
    public let computeUnits: MLComputeUnits

    /// `MLModel` 是线程安全的推理对象（Apple 文档：模型可在多线程上并发预测），
    /// 但其类型未标注 `Sendable`，故本类型以 `@unchecked Sendable` 声明。
    private let model: MLModel

    /// 从 bundle 装载模型；失败抛 `ScannerError.modelUnavailable`。
    public init(
        descriptor: DewarpModelDescriptor = .uvDoc,
        bundle: Bundle = .main,
        computeUnits: MLComputeUnits = .all
    ) throws {
        try self.init(
            modelURL: Self.resolveModelURL(descriptor: descriptor, bundle: bundle),
            descriptor: descriptor,
            computeUnits: computeUnits
        )
    }

    /// 从显式路径装载（测试与自测页用）；`.mlpackage` 会先编译成 `.mlmodelc`。
    public init(modelURL: URL, descriptor: DewarpModelDescriptor = .uvDoc, computeUnits: MLComputeUnits = .all) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let compiled = try Self.compileIfNeeded(modelURL, resourceName: descriptor.bundleResource)
        do {
            self.model = try MLModel(contentsOf: compiled, configuration: configuration)
        } catch {
            throw ScannerError.modelUnavailable(
                "\(descriptor.bundleResource) 装载失败：\(error.localizedDescription)"
            )
        }
        self.descriptor = descriptor
        self.computeUnits = computeUnits
    }

    /// `.mlmodelc` 直接返回；`.mlpackage` / `.mlmodel` 先编译（Core ML 只接受编译后的模型）。
    static func compileIfNeeded(_ url: URL, resourceName: String) throws -> URL {
        guard url.pathExtension != "mlmodelc" else { return url }
        do {
            return try MLModel.compileModel(at: url)
        } catch {
            throw ScannerError.modelUnavailable("\(resourceName) 编译失败：\(error.localizedDescription)")
        }
    }

    /// 在 bundle 内定位模型资源：优先已编译的 `.mlmodelc`，其次把 `.mlpackage` 就地编译。
    static func resolveModelURL(descriptor: DewarpModelDescriptor, bundle: Bundle) throws -> URL {
        let subdirectories: [String?] = [nil, "Models"]
        for subdirectory in subdirectories {
            if let url = bundle.url(
                forResource: descriptor.bundleResource,
                withExtension: "mlmodelc",
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        for subdirectory in subdirectories {
            guard let url = bundle.url(
                forResource: descriptor.bundleResource,
                withExtension: "mlpackage",
                subdirectory: subdirectory
            ) else { continue }
            return try compileIfNeeded(url, resourceName: descriptor.bundleResource)
        }
        throw ScannerError.modelUnavailable(
            "bundle 内找不到 \(descriptor.bundleResource).mlmodelc / .mlpackage（是否漏加 Models/ 资源）"
        )
    }

    public func predictGrid(for image: FloatImage) throws -> NormalizedSampleGrid {
        guard image.width == descriptor.inputWidth, image.height == descriptor.inputHeight else {
            throw ScannerError.modelUnavailable(
                "输入必须是 \(descriptor.inputWidth)×\(descriptor.inputHeight)，收到 \(image.width)×\(image.height)"
            )
        }
        guard image.channels == 3 else {
            throw ScannerError.modelUnavailable("输入必须是 3 通道 RGB，收到 \(image.channels) 通道")
        }
        AppLog.debug(
            "推理 \(descriptor.name)@\(descriptor.version)（\(image.width)×\(image.height)）",
            category: .dewarp
        )
        let provider = try MLDictionaryFeatureProvider(
            dictionary: [descriptor.inputName: MLFeatureValue(multiArray: try Self.inputArray(from: image))]
        )
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: provider)
        } catch {
            throw ScannerError.modelUnavailable("推理失败：\(error.localizedDescription)")
        }
        guard let grids = output.featureValue(for: descriptor.gridOutputName)?.multiArrayValue else {
            throw ScannerError.modelUnavailable("模型输出缺少 \(descriptor.gridOutputName)")
        }
        return try Self.normalizedGrid(from: grids, descriptor: descriptor)
    }

    /// 平面 Float32 图像 → `[1, 3, H, W]` MLMultiArray（两者线性布局一致，逐元素直拷）。
    static func inputArray(from image: FloatImage) throws -> MLMultiArray {
        let shape = [
            1,
            NSNumber(value: image.channels),
            NSNumber(value: image.height),
            NSNumber(value: image.width),
        ]
        let count = image.values.count
        let array: MLMultiArray
        do {
            array = try MLMultiArray(shape: shape, dataType: .float32)
        } catch {
            throw ScannerError.modelUnavailable("无法创建输入张量：\(error.localizedDescription)")
        }
        if array.dataType == .float32 {
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            for index in 0 ..< count {
                pointer[index] = image.values[index]
            }
        } else {
            for index in 0 ..< count {
                array[index] = NSNumber(value: image.values[index])
            }
        }
        return array
    }

    /// `[1, 2, rows, columns]` 网格张量 → `NormalizedSampleGrid`。
    static func normalizedGrid(from array: MLMultiArray, descriptor: DewarpModelDescriptor) throws -> NormalizedSampleGrid {
        let shape = array.shape.map(\.intValue)
        guard shape.count == 4, shape[0] == 1, shape[1] >= 2 else {
            throw ScannerError.modelUnavailable("网格张量形状异常：\(shape)")
        }
        let rows = shape[2]
        let columns = shape[3]
        guard rows == descriptor.gridRows, columns == descriptor.gridColumns else {
            throw ScannerError.modelUnavailable(
                "网格分辨率与描述不符：模型 \(rows)×\(columns)，描述 \(descriptor.gridRows)×\(descriptor.gridColumns)"
            )
        }
        let planeSize = rows * columns
        var xValues = [Float](repeating: 0, count: planeSize)
        var yValues = [Float](repeating: 0, count: planeSize)
        for index in 0 ..< planeSize {
            xValues[index] = array[index].floatValue
            yValues[index] = array[planeSize + index].floatValue
        }
        return NormalizedSampleGrid(columns: columns, rows: rows, xValues: xValues, yValues: yValues)
    }
}
