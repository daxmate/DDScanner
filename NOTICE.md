# NOTICE

DDScanner — Copyright 2026 daxmate. Licensed under the Apache License, Version 2.0 (see `LICENSE`).

## Third-party components

| Component | Use | License | Upstream |
|---|---|---|---|
| PaddleOCR (incl. UVDoc integration) | Model code lineage for the dewarp backend | Apache-2.0 | https://github.com/PaddlePaddle/PaddleOCR |
| UVDoc (original implementation) | Dewarp model architecture | MIT | https://github.com/tanguymagne/UVDoc |

### References

- UVDoc: *UVDoc: Neural Grid-based Document Unwarping* (Verhoeven, Magne, et al., SIGGRAPH Asia 2023).
- PaddleOCR: *PaddleOCR: Awesome multilingual OCR toolkits* (Du et al.).
- PaddleOCR is released under the Apache License 2.0; its `LICENSE` full text is retained by
  upstream and must be carried along with any redistributed copy.

> Model weights are **not** vendored in this repository at this time. When a converted
> `.mlpackage` is added, the conversion script and the produced artifact must land in the
> same change (see `docs/model-supply-chain.md`), together with the upstream license text
> and the "modified" notice required by Apache-2.0 §4(b).
