# NOTICE

DDScanner — Copyright 2026 daxmate. Licensed under the Apache License, Version 2.0 (see `LICENSE`).

## Third-party components

| Component | Use | License | Upstream |
|---|---|---|---|
| PaddleOCR (incl. UVDoc integration) | Model code lineage for the dewarp backend | Apache-2.0 | https://github.com/PaddlePaddle/PaddleOCR |
| UVDoc (original implementation) | Dewarp model architecture + the weights we convert | MIT | https://github.com/tanguymagne/UVDoc |

### References

- UVDoc: *UVDoc: Neural Grid-based Document Unwarping* — **Floor Verhoeven, Tanguy Magne,
  Olga Sorkine-Hornung**, SIGGRAPH Asia 2023 (Conference Papers). Project page:
  https://igl.ethz.ch/projects/uvdoc/
- PaddleOCR: *PaddleOCR: Awesome multilingual OCR toolkits* (Du et al.).
- PaddleOCR is released under the Apache License 2.0; its `LICENSE` full text is retained by
  upstream and must be carried along with any redistributed copy.

## Vendored model artifacts

`Models/UVDocGrid_fp16.mlpackage` is **derived from** the original UVDoc checkpoint
(`tanguymagne/UVDoc`, `model/best_model.pkl`, sha256
`7e90861b8a516eb4bc51f84bd889cb77275743d2d1d3ca8091951ec9f2b7da23`). Upstream is **MIT**;
the conversion was produced by `Tools/ModelConvert/convert_uvdoc.py` (see
`docs/model-supply-chain.md` and `Models/README.md`).

**Modifications** applied to the upstream artifact:

1. Re-serialised from PyTorch (`.pkl` state dict) to Core ML `mlprogram` with FLOAT16 compute
   precision (`minimum_deployment_target = iOS17`) and a fixed input shape `1×3×712×488`.
2. The network is exported to emit **two sampling grids only**. The unwarping step that upstream
   runs outside the network (`F.interpolate` + `F.grid_sample`) is not part of the artifact; it is
   reimplemented in Swift in `Sources/DDScannerCore` (Float32). The network's learned weights are
   unmodified — no retraining or fine-tuning.

Attribution retained as required by the MIT License (Copyright (c) the UVDoc authors, ETH Zurich):

```
MIT License

Copyright (c) UVDoc authors (ETH Zurich) — https://github.com/tanguymagne/UVDoc

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The upstream checkpoint itself is **not** redistributed in this repository: only the converted
Core ML artifact is vendored, and `Tools/ModelConvert/` documents how to obtain the original
weights and verify their hash.
