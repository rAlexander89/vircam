# Viracm

A virtual camera that keeps **only you** sharp and blurs every other person and face,
on your own machine. Calling apps (Zoom, Google Meet, or anything with a camera picker)
use it like a normal webcam.

![Zoom, Google Meet, and Viracm side by side](docs/comparison.png)

*Left: Zoom's background blur. Middle: Google Meet's. Right: Viracm. Zoom and Meet keep
the child's face in the photo sharp because it looks like a person. Viracm blurs it.*

## Why built-in blur leaks faces

Zoom and Meet split each frame into "person" and "background" and keep anything that
looks like a person sharp. A face behind you, or in a photo you hold up, is also a
person, so it stays sharp. Their masks are also recomputed every frame, so one
low-confidence frame can briefly show a face that was blurred a moment before.

## How Viracm blurs all other faces

Viracm works the other way around: **the whole frame is blurred by default, and only
you are allowed to be sharp.**

1. **Find you.** Every face is detected and tracked frame to frame. The largest face,
   seen consistently, is treated as you. Someone else has to be clearly larger for half
   a second before they take over, so a person leaning in can't steal the spot.
2. **Keep only your outline sharp.** Each person's outline is detected separately
   (Apple Vision on macOS). Only the outline that contains your face is kept sharp.
   Everyone else, including people standing right next to you, stays blurred.
3. **Blur faces that overlap you.** If another face overlaps your outline, such as
   someone leaning over your shoulder, it is blurred even more heavily on top.
4. **Don't let faces flicker back.** A face the detector loses keeps its blur where it
   was last seen for 0.75 s.
5. **Fail closed.** If no single person can be confirmed as you, if you leave the frame
   for more than a second, or if anything errors, the entire frame is blurred. The raw
   camera feed is never sent.

Everything runs locally. No video leaves your computer.

## Status

| Platform | State |
|----------|-------|
| macOS 14+ (Apple silicon) | App works with a live preview. The "Viracm Camera" system extension that Zoom and Meet select needs a paid Apple Developer team to sign it. |
| Linux | Planned (v4l2loopback output, same C++ core). |

See [PLAN.md](PLAN.md) for the architecture and milestones.

## Build (macOS)

Requires Xcode 16, CMake, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install cmake xcodegen`).

```sh
make deps   # downloads ONNX Runtime and the face model, verifying checksums
make test   # core unit tests
make run    # builds and opens the app
```

To install the camera extension, copy `mac/Config/Local.xcconfig.example` to
`mac/Config/Local.xcconfig`, set your team ID, rebuild, move `Viracm.app` to
`/Applications`, and click **Install…** in the app.

To try the pipeline on a photo:

```sh
build/xcode/Build/Products/Debug/Viracm.app/Contents/MacOS/Viracm --process-image photo.jpg out.png --debug
```
