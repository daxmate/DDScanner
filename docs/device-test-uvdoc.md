# 真机测试指引 —— 去畸变自测页（UVDoc）

> 目标：在**真机**上量出 UVDoc 网格模型的实际耗时，并用肉眼确认「校正前后」的效果。
> 这一页只在 **Debug** 构建里存在，**不需要模拟器**。
> 背景数字（Mac M5 Pro，FP16 ANE 中位 **2.28 ms**）只是指示值——**真机以本页数字为准**。

## 一、准备（一次性）

1. iPhone（iOS **17+**）用数据线连上 Mac，手机上点「信任此电脑」。
2. Mac 上装好 Xcode（本仓用 Xcode 27 / iOS 17 部署目标）。
3. 签名：打开工程后选中 `DDScanner` target → **Signing & Capabilities** → 勾
   *Automatically manage signing* → Team 选你自己的 Apple ID（免费账号够用）。

## 二、构建到手机

```bash
cd <仓库路径>                 # 维护者合入 main 后，这里就是 main 的检出
open DDScanner.xcodeproj
```

1. Xcode 左上：Scheme 选 **DDScanner**（不是 DDScannerContractTests）。
2. 设备目标选你那台 **iPhone**（不要选任何 Simulator）。
3. **⌘R** 运行。首次安装需在 iPhone 设置 → 通用 → VPN与设备管理 里信任该开发者证书。

## 三、打开自测页

首页右上角有一个**心电图图标**（`waveform.path.ecg`，仅在 Debug 构建出现）→ 点它。

页面会自动跑一次（约 1–3 秒），也可以点右上角「重跑」再来一次。

## 四、页面上读什么

| 行 | 含义 | 怎么看 |
|---|---|---|
| 模型状态 | 是否装载成功 | 应显示「已装载 UVDocGrid_fp16（computeUnits=all）」；显示红色「模型不可用：…」= 资源没打进包（**不崩**，属降级路径） |
| 算力（MLComputeUnits） | 请求的算力单元 | `all` 表示允许走 ANE；若 median 明显偏大，可对比 `cpuOnly`（需改装配参数，非本批范围） |
| 设备 / 系统 | 机型标识 + 系统版本 | 截图回报时**必须有这一行** |
| 输入尺寸 / 输出网格 | 模型契约 | 应为 `488×712` / `31×45`（对不上说明产物与代码不同步） |
| **推理 min / median / max** | 30 次推理的耗时分布（ms） | **median 是主指标**；min 与 median 差距大 = 有抖动 |
| 单次均耗时（含首跑） | 30 次总耗时 ÷ 30 | 含首次预热，会略高于 median |
| 预处理（缩放到输入） | 样例图 → 488×712 RGB Float32 | 与模型无关，只为参考 |
| 全分辨率重采样 | Swift 侧 Float32 去畸变 | 这是替换掉「模型内 FP16 重采样」的那一步，量级应在几十 ms 内 |
| 对比图 | 左：原图（弯曲书页）／右：重采样结果 | 校正后表格线应变直、行距均匀、页面基本充满画面 |

## 五、判读与回报

1. **成绩数字**：回报「推理 median / min / max（ms）」+「机型 + iOS 版本」+「computeUnits」。
2. **效果**：对比左右两图，回答一句「右侧页面是否变平整（表格线变直 / 行距均匀）」。
   仍然弯曲、出现波浪、边缘被拉伸截断 = 校正不达标，请截图。
3. **稳定性**：连点几次「重跑」，median 是否稳定（±20% 以内算稳定）。
4. **回报方式**：直接截整页图（含上表所有行）发给维护者即可。

## 六、这是本批**不**包含的东西

- 没有相机、拍摄、边缘检测、四角微调：自测页只跑**内置合成样张**（`Resources/DevSampleDocument.jpg`，
  程序生成的弯曲书页，**不含任何个人信息**）。
- 直线透视畸变由 Core Image 负责，本批不接管线；自测页只验证 UVDoc 网格这一环。
- 自测页不做 UI 打磨，够用就行。

## 七、降级路径（可选验证）

如果把 `Models/` 从工程资源里去掉再构建（或产物没打进包），页面应显示
「模型不可用：bundle 内找不到 UVDocGrid_fp16.mlmodelc / .mlpackage（是否漏加 Models/ 资源）」，
**页面其余部分照常显示、App 不崩**。同一条降级逻辑在 macOS 侧有自动化测试守着：
`swift test --package-path Sources/DDScannerDewarp`（用例「模型缺失时抛 modelUnavailable」）。
