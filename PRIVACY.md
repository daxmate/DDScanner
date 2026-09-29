# Privacy

DDScanner is a local-first document scanner. This document describes what the app touches
and why; it is the source of truth for the App Store privacy answers.

## Data the app accesses

| Permission | Why | Where it goes |
|---|---|---|
| Camera (`NSCameraUsageDescription`) | Capture document pages for scanning | Frames are processed **on device**; nothing is uploaded. |
| Photo library read (`NSPhotoLibraryUsageDescription`) | Import existing images/documents for scanning | Read on device, on explicit user action. |
| Photo library add (`NSPhotoLibraryAddUsageDescription`) | Save exported scans back to the library | Written only when the user asks to save. |
| Files (document picker) | Import/export PDFs at user-selected locations | User-selected paths only. |

## Data the app does not collect

- No account, no sign-in, no analytics SDK, no advertising SDK, no crash-reporting SDK.
- No document content, image, or OCR text leaves the device.
- No network calls are made in the current baseline (no network entitlement is used).

## Permissions policy

- Every permission is requested **at the moment of use**, never on first launch.
- Denial is a supported state: the app must degrade to an explanation, never crash or loop.

## Changes

Any feature that would upload content, add a third-party analytics SDK, or introduce a
server component requires updating this file **in the same change** and re-auditing the
App Store privacy answers.
