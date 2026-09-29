#!/usr/bin/env python3
"""UVDoc (original PyTorch, MIT) -> Core ML grid model, for DDScanner.

Produces the *grid-only* Core ML model that the iOS app runs: the network emits two
sampling grids and nothing else. The unwarping (`F.interpolate` + `F.grid_sample`,
see `utils.bilinear_unwarping` upstream) is deliberately NOT part of the model — the
Swift side resamples in Float32. Rationale and measurements: `Tools/ModelConvert/README.md`
and the spike conclusion it cites.

Contract (must match `Sources/DDScannerDewarp/.../CoreMLDewarpBackend.swift`):
    input  : image,  (1, 3, H, W)  float32, RGB in [0, 1]
    output : point_positions2D  (1, 2, 45, 31)  <- the sampling grid (normalized)
             point_positions3D  (1, 3, 45, 31)  <- unused by the app, kept for fidelity
    grid size: 45x31 for a 712x488 input (encoder downsamples by 16, rounded up).

Usage (see README.md for the venv/dependency setup):
    python convert_uvdoc.py \
        --uvdoc-source /path/to/UVDoc \
        --weights /path/to/UVDoc/model/best_model.pkl \
        --output Models/UVDocGrid_fp16.mlpackage \
        --verify

`--uvdoc-source` must be a checkout of https://github.com/tanguymagne/UVDoc (MIT); the
network definition (`model.py`) is imported from there rather than vendored here, so the
architecture cannot silently drift from upstream. `--verify` re-runs both frameworks on a
deterministic input and aborts if the grid error exceeds the documented tolerance.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
from typing import Any

# Fixed export shape (H, W). The app feeds 712x488 because the upstream demo calls
# cv2.resize(img, (488, 712)). Changing this changes the output grid size (encoder
# downsamples by 16: 712x488 -> 45x31, i.e. ceil(), not a clean division).
DEFAULT_HEIGHT = 712
DEFAULT_WIDTH = 488

# Tolerances for --verify, from the spike's measured numbers (README.md, Q-b):
# FP32 grid error ~1e-6; FP16 reaches ~1e-2 worst case (CPU) / ~4e-4 on ANE.
VERIFY_TOLERANCE = {float: 1e-4, "float16": 3e-2}


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Convert UVDoc (PyTorch, MIT) to a Core ML grid model.")
    parser.add_argument(
        "--uvdoc-source",
        required=True,
        help="path to a checkout of https://github.com/tanguymagne/UVDoc (contains model.py)",
    )
    parser.add_argument(
        "--weights",
        required=True,
        help="path to the upstream checkpoint model/best_model.pkl (not vendored in this repo)",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="path of the .mlpackage to write (e.g. Models/UVDocGrid_fp16.mlpackage)",
    )
    parser.add_argument("--height", type=int, default=DEFAULT_HEIGHT, help=f"input height in px (default {DEFAULT_HEIGHT})")
    parser.add_argument("--width", type=int, default=DEFAULT_WIDTH, help=f"input width in px (default {DEFAULT_WIDTH})")
    parser.add_argument(
        "--precision",
        choices=["float16", "float32"],
        default="float16",
        help="compute precision (default float16: fastest on ANE and ~16 MB)",
    )
    parser.add_argument(
        "--deployment-target",
        default="iOS17",
        choices=["iOS17", "iOS18", "iOS26"],
        help="minimum Core ML deployment target (default iOS17, this app's minimum)",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="compare the converted model against the traced PyTorch reference on a fixed input",
    )
    return parser.parse_args(argv)


def load_upstream_module(uvdoc_source: str) -> Any:
    """Import `model.UVDocnet` from the upstream checkout (empty __init__.py, sys.path insert)."""
    source = os.path.abspath(uvdoc_source)
    model_py = os.path.join(source, "model.py")
    if not os.path.isfile(model_py):
        raise SystemExit(f"❌ {model_py} 不存在：--uvdoc-source 必须指向 UVDoc 仓库检出（含 model.py）")
    sys.path.insert(0, source)
    import model  # noqa: PLC0415  (import must follow the sys.path insert)

    return model


def build_traced_model(model_module: Any, weights_path: str, height: int, width: int) -> tuple[Any, Any, Any, tuple[int, int]]:
    """Load the checkpoint, trace + freeze, and report the grid shape the network really emits."""
    import torch  # noqa: PLC0415

    torch.set_grad_enabled(False)
    checkpoint = torch.load(weights_path, map_location="cpu", weights_only=False)
    network = model_module.UVDocnet(num_filter=32, kernel_size=5)
    network.load_state_dict(checkpoint["model_state"], strict=True)
    network.eval()
    example = torch.randn(1, 3, height, width)
    with torch.no_grad():
        grid_2d, _ = network(example)
    grid_shape = (int(grid_2d.shape[2]), int(grid_2d.shape[3]))
    traced = torch.jit.trace(network, example, strict=False)
    traced = torch.jit.freeze(traced)
    return network, traced, example, grid_shape


def convert(
    traced: Any,
    height: int,
    width: int,
    grid_shape: tuple[int, int],
    precision: str,
    deployment_target: str,
    weights_sha: str,
) -> Any:
    import coremltools as ct  # noqa: PLC0415

    coreml_precision = ct.precision.FLOAT16 if precision == "float16" else ct.precision.FLOAT32
    target = {
        "iOS17": ct.target.iOS17,
        "iOS18": ct.target.iOS18,
        "iOS26": ct.target.iOS26,
    }[deployment_target]
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=(1, 3, height, width), dtype=float)],
        outputs=[
            ct.TensorType(name="point_positions2D"),
            ct.TensorType(name="point_positions3D"),
        ],
        convert_to="mlprogram",
        compute_precision=coreml_precision,
        minimum_deployment_target=target,
    )
    grid_height, grid_width = grid_shape
    mlmodel.short_description = (
        f"UVDoc grid predictor (tanguymagne/UVDoc, MIT) — {precision} mlprogram, "
        f"fixed input 1x3x{height}x{width}, grid {grid_height}x{grid_width}. "
        "Emits sampling grids only; resampling is done in Float32 on the Swift side."
    )
    mlmodel.author = "DDScanner"
    mlmodel.license = "MIT (model architecture and weights: https://github.com/tanguymagne/UVDoc)"
    mlmodel.version = f"uvdoc-{precision}-{height}x{width}"
    mlmodel.user_defined_metadata["weights_sha256"] = weights_sha
    mlmodel.user_defined_metadata["source"] = "https://github.com/tanguymagne/UVDoc"
    mlmodel.user_defined_metadata["generator"] = "Tools/ModelConvert/convert_uvdoc.py"
    return mlmodel


def verify(network: Any, mlmodel: Any, height: int, width: int, precision: str) -> None:
    """Deterministic-fixed comparison: traced PyTorch grid vs the shipped Core ML grid."""
    import numpy as np  # noqa: PLC0415
    import torch  # noqa: PLC0415

    torch.manual_seed(0)
    sample = torch.rand(1, 3, height, width)
    with torch.no_grad():
        reference_2d, reference_3d = network(sample)
    predictions = mlmodel.predict({"image": sample.numpy().astype(np.float32)})
    tolerance = VERIFY_TOLERANCE[float if precision == "float32" else "float16"]
    for name, reference in (("point_positions2D", reference_2d), ("point_positions3D", reference_3d)):
        actual = np.asarray(predictions[name])
        maximum = float(np.max(np.abs(actual - reference.numpy())))
        status = "✅" if maximum <= tolerance else "❌"
        print(f"  {status} {name}: max_abs_diff={maximum:.6g} (容差 {tolerance:g})")
        if maximum > tolerance:
            raise SystemExit(f"❌ {name} 数值误差 {maximum:.6g} 超过容差 {tolerance:g}，产物不可信")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    weights_sha = sha256_of(args.weights)
    source_sha = sha256_of(os.path.join(os.path.abspath(args.uvdoc_source), "model.py"))
    print("▶ 来源取证")
    print(f"  weights  sha256 = {weights_sha}")
    print(f"  model.py sha256 = {source_sha}")

    model_module = load_upstream_module(args.uvdoc_source)
    network, traced, _, grid_shape = build_traced_model(model_module, args.weights, args.height, args.width)
    print(f"▶ 已加载权重并 trace（输入 1x3x{args.height}x{args.width}，输出网格 {grid_shape[0]}x{grid_shape[1]}）")

    mlmodel = convert(
        traced, args.height, args.width, grid_shape, args.precision, args.deployment_target, weights_sha
    )
    output = os.path.abspath(args.output)
    os.makedirs(os.path.dirname(output), exist_ok=True)
    mlmodel.save(output)
    print(f"▶ 已写出 {output}")

    if args.verify:
        print(f"▶ 数值自校验（--{args.precision}，容差见脚本常量）")
        verify(network, mlmodel, args.height, args.width, args.precision)

    print("✅ 转换完成")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
