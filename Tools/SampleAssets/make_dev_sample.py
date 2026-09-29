#!/usr/bin/env python3
"""生成 DDScanner「去畸变自测页」用的内置样例文档图（**合成图，无任何真实单据/个人信息**）。

为什么要合成：真实拍摄的文档照片会带隐私与肖像/版权风险，而自测页是开发用页面、
要随仓库分发。这里用程序渲染一页印刷文本，再套一个可解析的「书页弯曲」畸变模型
（竖直轴圆柱 + 透视投影），效果与真实弯曲书页同族，且**完全可复现、无第三方权利**。

畸变模型（逆映射，逐输出像素求值）：
    θ(x) ∈ [0, θ_max] 为页面横向弧长参数；R 为曲率半径；相机在 (0, 0, D) 朝 -z 看。
        世界点 P(θ, y) = (R sinθ, y, R cosθ)，深度 depth = D - R cosθ
        屏幕坐标： X = R sinθ / depth        （透视：越远越窄）
                   Y = y / depth             （透视：越远越向中心收 → 横线“弯”）
    X 只依赖 θ ⇒ 每列先用二分法解出 θ，再由 depth 反推页面 y，最后双线性取页面像素。

输出：Resources/DevSampleDocument.jpg（JPEG，约 200 KB）。

用法：
    python3.13 -m venv /tmp/sample-venv && /tmp/sample-venv/bin/pip install pillow numpy
    /tmp/sample-venv/bin/python Tools/SampleAssets/make_dev_sample.py \
        --output Resources/DevSampleDocument.jpg
"""

from __future__ import annotations

import argparse
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

# --- 页面与世界参数（world 单位）----------------------------------------------
PAGE_WIDTH = 900
CURVE_RADIUS = 3.0  # R：曲率半径（越大越平）
THETA_MAX = 0.35  # 弧度（约 20°）的弯曲量
CAMERA_DISTANCE = 4.5  # D：相机到圆柱轴的距离
HALF_HEIGHT = 0.75  # 页面半高
PAGE_ASPECT = CURVE_RADIUS * THETA_MAX / (2 * HALF_HEIGHT)  # 页面自身宽高比 ≈ 0.7
PAGE_HEIGHT = int(round(PAGE_WIDTH / PAGE_ASPECT))
OUTPUT_HEIGHT = 1700
MARGIN_RATIO = 0.03  # 画布四周留白（占页面渲染尺寸比例）

TITLE = "DDScanner 去畸变自测样张"
SUBTITLE = "合成图像 · 无个人信息 · 由 Tools/SampleAssets/make_dev_sample.py 生成"
PARAGRAPH = [
    "本文档用于验证文档去畸变（dewarp）后端：书页弯曲、透视畸变等非线性",
    "形变应被网格模型校正为平整页面。样张文本为占位内容，不含真实数据。",
    "",
    "The quick brown fox jumps over the lazy dog. 0123456789",
    "Pack my box with five dozen liquor jugs. !@#$%^&*()",
    "",
    "验收观察点：水平文本行应恢复为直线，行距均匀，左右边距一致；",
    "若出现波浪、拉伸或边缘截断，即为校正失败或网格约定不匹配。",
    "网格模型只输出采样网格，重采样由 Swift 侧以 Float32 完成，",
    "因此像素误差只应来自模型精度与插值，不应来自半精度量化。",
]
FONT_CANDIDATES = (
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",  # 含 CJK 字形
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/STHeiti Light.ttc",
)


def load_font(size: int) -> ImageFont.FreeTypeFont:
    """优先选带 CJK 字形的字体，否则中文会渲染成豆腐块。"""
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    raise SystemExit("❌ 找不到含 CJK 字形的候选字体")


def render_page() -> Image.Image:
    """渲染一页平整的印刷文本（含表格，作为「直线/直角」参照物）。"""
    page = Image.new("RGB", (PAGE_WIDTH, PAGE_HEIGHT), (252, 251, 248))
    draw = ImageDraw.Draw(page)
    margin = 62
    title_font = load_font(38)
    subtitle_font = load_font(18)
    body_font = load_font(24)

    draw.text((margin, 58), TITLE, font=title_font, fill=(24, 24, 28))
    draw.text((margin, 116), SUBTITLE, font=subtitle_font, fill=(110, 112, 120))
    draw.line([(margin, 156), (PAGE_WIDTH - margin, 156)], fill=(120, 122, 130), width=2)

    line_y = 190
    for line in PARAGRAPH:
        if line:
            draw.text((margin, line_y), line, font=body_font, fill=(38, 38, 44))
        line_y += 46

    # 表格块：网格校正后应为规整矩形。
    table_top = line_y + 34
    table_left, table_right = margin, PAGE_WIDTH - margin
    rows, columns = 4, 3
    row_height = 68
    for index in range(rows + 1):
        y = table_top + index * row_height
        draw.line([(table_left, y), (table_right, y)], fill=(90, 92, 100), width=2)
    for index in range(columns + 1):
        x = table_left + (table_right - table_left) * index // columns
        draw.line([(x, table_top), (x, table_top + rows * row_height)], fill=(90, 92, 100), width=2)
    for row in range(rows):
        for column in range(columns):
            cell_x = table_left + (table_right - table_left) * column // columns + 22
            cell_y = table_top + row * row_height + 18
            draw.text((cell_x, cell_y), f"R{row + 1}C{column + 1}", font=subtitle_font, fill=(70, 72, 80))

    draw.text(
        (margin, PAGE_HEIGHT - 78),
        "第 1 页 / 共 1 页    样张版本 v1（2026-09-29）",
        font=subtitle_font,
        fill=(120, 122, 130),
    )
    return page


def screen_x(theta: np.ndarray | float) -> np.ndarray | float:
    return CURVE_RADIUS * np.sin(theta) / (CAMERA_DISTANCE - CURVE_RADIUS * np.cos(theta))


def theta_for(target: np.ndarray) -> np.ndarray:
    """对每个屏幕 X（world 单位）二分求 θ；无解（背景）返回 NaN。"""
    result = np.full(target.shape, np.nan, dtype=np.float64)
    valid = (target >= 0) & (target <= float(screen_x(THETA_MAX)))
    if not valid.any():
        return result
    low = np.zeros(target.shape)
    high = np.full(target.shape, THETA_MAX)
    for _ in range(64):
        mid = 0.5 * (low + high)
        low = np.where(screen_x(mid) < target, mid, low)
        high = np.where(screen_x(mid) < target, high, mid)
    result[valid] = 0.5 * (low[valid] + high[valid])
    return result


def bilinear(source: np.ndarray, sample_x: np.ndarray, sample_y: np.ndarray, inside: np.ndarray) -> np.ndarray:
    height, width = source.shape[:2]
    safe_x = np.where(inside, sample_x, 0.0)
    safe_y = np.where(inside, sample_y, 0.0)
    x0 = np.clip(np.floor(safe_x), 0, width - 1).astype(int)
    y0 = np.clip(np.floor(safe_y), 0, height - 1).astype(int)
    x1 = np.clip(x0 + 1, 0, width - 1)
    y1 = np.clip(y0 + 1, 0, height - 1)
    fraction_x = (safe_x - x0)[..., None]
    fraction_y = (safe_y - y0)[..., None]
    top = source[y0, x0] * (1 - fraction_x) + source[y0, x1] * fraction_x
    bottom = source[y1, x0] * (1 - fraction_x) + source[y1, x1] * fraction_x
    return top * (1 - fraction_y) + bottom * fraction_y


def warp(page: Image.Image, background: tuple[int, int, int] = (58, 60, 66)) -> Image.Image:
    """把平整页面渲染成「照片里弯曲的书页」，页面基本充满画面。"""
    near_depth = CAMERA_DISTANCE - CURVE_RADIUS
    far_depth = CAMERA_DISTANCE - CURVE_RADIUS * np.cos(THETA_MAX)
    world_width = float(screen_x(THETA_MAX))
    world_height = 2 * HALF_HEIGHT / near_depth

    scale = OUTPUT_HEIGHT / world_height
    canvas_width = int(round(world_width * scale * (1 + 2 * MARGIN_RATIO)))
    canvas_height = int(round(OUTPUT_HEIGHT * (1 + 2 * MARGIN_RATIO)))
    center_x = world_width / 2  # 页面世界坐标不关于 0 对称，必须按包围盒中心对中

    columns = np.arange(canvas_width, dtype=np.float64)
    rows = np.arange(canvas_height, dtype=np.float64)
    world_x = center_x + (columns - (canvas_width - 1) / 2) / scale
    world_y = ((canvas_height - 1) / 2 - rows) / scale
    grid_x, grid_y = np.meshgrid(world_x, world_y)

    theta = theta_for(grid_x)
    depth = CAMERA_DISTANCE - CURVE_RADIUS * np.cos(theta)
    plane_y = grid_y * depth  # 反推页面 world 高度坐标
    page_x = theta / THETA_MAX * (PAGE_WIDTH - 1)
    page_y = (HALF_HEIGHT - plane_y) / (2 * HALF_HEIGHT) * (PAGE_HEIGHT - 1)
    inside = (
        np.isfinite(theta)
        & (page_x >= 0)
        & (page_x <= PAGE_WIDTH - 1)
        & (page_y >= 0)
        & (page_y <= PAGE_HEIGHT - 1)
    )

    rendered = bilinear(np.asarray(page, dtype=np.float64), page_x, page_y, inside)

    # 光照：越远越暗（曲面背光），再叠一层很轻的竖直渐变。
    distance_t = np.clip((depth - near_depth) / (far_depth - near_depth), 0, 1)
    brightness = 1.0 - 0.20 * distance_t
    vertical = 1.0 - 0.03 * np.abs((np.arange(canvas_height) / canvas_height) - 0.5)[:, None]
    rendered = rendered * (brightness * vertical)[..., None]

    result = np.empty(rendered.shape, dtype=np.float64)
    result[...] = np.array(background, dtype=np.float64)
    result[inside] = rendered[inside]
    image = Image.fromarray(np.clip(result, 0, 255).astype(np.uint8))

    # 轻微模糊 + 噪点，让它更像照片而不是矢量图（固定种子，可复现）。
    image = image.filter(ImageFilter.GaussianBlur(0.6))
    noise = np.random.default_rng(20260929).normal(0, 2.2, (canvas_height, canvas_width, 1))
    noisy = np.clip(np.asarray(image, dtype=np.float64) + noise, 0, 255)
    return Image.fromarray(noisy.astype(np.uint8))


def main() -> int:
    parser = argparse.ArgumentParser(description="生成去畸变自测页的内置样例文档图（合成，无个人信息）。")
    parser.add_argument("--output", required=True, help="输出 JPEG 路径，例如 Resources/DevSampleDocument.jpg")
    parser.add_argument("--quality", type=int, default=88, help="JPEG 质量（默认 88）")
    args = parser.parse_args()

    image = warp(render_page())
    output = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(output), exist_ok=True)
    image.save(output, "JPEG", quality=args.quality)
    print(f"✅ 已写出 {output}（{image.width}×{image.height}，{os.path.getsize(output) / 1024:.0f} KB）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
