# Vircam plan

A virtual camera for macOS and Linux that keeps only the user sharp and blurs every
other person and face, using local hardware only. Calling apps (Zoom, Google Meet,
anything with a camera picker) select "Vircam Camera" like a normal webcam.

## Why existing blur leaks faces

Zoom/Meet blur uses semantic "person vs background" segmentation. A person behind you
is still "person", so they stay sharp, and per-frame masks flicker, so a single
low-confidence frame shows the face.

## Privacy rules (shared by every platform)

1. **Allowlist, not denylist.** Start from a fully blurred frame; only the primary
   person's instance mask is kept sharp.
2. **Primary person = largest face.** Another face only takes over if it stays
   clearly larger (1.5x) for a sustained period (hysteresis). Later: enrolled identity.
3. **Every non-primary face is blurred again** over an expanded box (1.3x), even if it
   overlaps the primary person's mask.
4. **Persistence.** A lost face keeps its blur region for 0.75 s.
5. **Fail closed.** Errors, no primary person for >1 s, or a stalled pipeline produce a
   fully blurred frame (in the app) or a "Vircam is not running" frame (in the camera).
   Raw camera frames are never sent.

## Architecture

```
┌──────────── platform shell ────────────┐      ┌──────── core/ (C++, shared) ────────┐
│ macOS: Swift — AVFoundation capture,   │      │ face detection (YuNet)              │
│   SwiftUI UI, CMIO camera extension    │ ───► │ person instance segmentation        │
│ Linux: C++ — V4L2 capture,             │ ◄─── │ privacy rules + tracking            │
│   v4l2loopback output                  │      │ blur / compositing                  │
└────────────────────────────────────────┘      └─────────────────────────────────────┘
               BGRA frame in ──► processed BGRA frame out (C API: core/include/vircam/vircam.h)
```

Face detection runs on ONNX Runtime (Core ML on macOS; CUDA/OpenVINO/ROCm/CPU on Linux).
Person outlines come from the platform: Apple Vision on macOS, an ONNX model on Linux; the
core picks which outline is the user's and applies the same privacy rules either way.
Model licenses must allow redistribution: YuNet, SFace (OpenCV zoo), RTMDet-Ins (Apache 2.0).
Avoid YOLOv8/11 (AGPL) and InsightFace models (non-commercial).

## Milestones

| #  | Deliverable | Status |
|----|-------------|--------|
| M1 | Skeleton: C++ core (fail-closed full blur), Swift app with capture + preview, camera extension (sink → source, placeholder frame), build scripts | done (extension builds; untested until signed) |
| M2 | Face detection (YuNet, Core ML GPU) + tracking + privacy rules in the core; `vircam_cli` photo tool (`make process IMAGE=...`). Interim sharp region is a head-and-shoulders shape | done |
| M3 | Person outlines: Apple Vision instance masks on macOS, passed to the core (`vircam_engine_process_with_masks`); head-and-shoulders shape only as fallback. Gaussian blur with person-excluded (halo-free) background. Linux needs its own segmentation model (M6) | done (macOS) |
| M4 | Signed camera extension installed and verified in Zoom, Meet, and other apps (needs paid Apple Developer team) | |
| M5 | Hardening: latency budget, adversarial scenes (lean-in, walk-by, low light), shared test fixtures | |
| M6 | Linux shell: V4L2 capture, v4l2loopback output, udev rule to hide the real camera | |
| Later | Identity enrollment (SFace) | |

## Signing (macOS)

Camera extensions only load when signed by a paid Apple Developer team. Until then the
app runs ad-hoc signed: capture, processing, and preview work; the extension is built
but cannot be activated. To sign, copy `mac/Config/Local.xcconfig.example` to
`mac/Config/Local.xcconfig` and set the team ID.
