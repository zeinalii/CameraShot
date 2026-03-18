# CameraShot

High-performance macOS camera capture tool written in Swift + AVFoundation.  
Saves a JPEG from any connected camera every **N** seconds.

## Why Swift / AVFoundation

| What | How |
|---|---|
| Zero-latency preview | `AVCaptureVideoPreviewLayer` as the NSView's own backing layer — frames go GPU → display with **zero CPU copies** |
| Frame capture | `AVCaptureVideoDataOutput` on a dedicated `.userInteractive` queue, late frames discarded immediately |
| JPEG encoding | Metal-backed `CIContext` — hardware accelerator, not the CPU |
| Save I/O | Dedicated serial queue, never blocks capture or the UI |
| Auto-focus / exposure | Locked to `continuousAutoFocus` + `continuousAutoExposure` for sharpest frames |
| Frame rate | Requests up to 60 fps (`activeVideoMinFrameDuration = 1/60`) |

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools (`xcode-select --install`)

No third-party dependencies.

## Build

```bash
cd CameraShot
make build
```

This produces `CameraShot.app` — a minimal, ad-hoc-signed app bundle that gives the binary access to the camera permission dialog.

## Run

```bash
# Camera menu + 5-second interval
make run ARGS="5"

# Camera index 1, 10-second interval
make run ARGS="10 1"

# Or run the binary directly
./CameraShot.app/Contents/MacOS/CameraShot <interval_seconds> [camera_index]
```

**Arguments:**

| # | Name | Default | Description |
|---|---|---|---|
| 1 | `interval_seconds` | — | Seconds between saved frames (e.g. `5`) |
| 2 | `camera_index` | interactive menu | Camera to use (0 = first, 1 = second, …) |

## Output

Frames are saved to `~/Desktop/CameraShots/frame_YYYYMMDD_HHMMSS.jpg` at 92 % JPEG quality.

## Notes

- **Zoom / Teams conflict** — if the target app has exclusive camera access, quit it first, or pass a different camera index to use a different device (e.g. a continuity camera or USB webcam).
- **Resolution** — the session requests 4K, falls back to 1080p, then "high", depending on what the camera supports.
- **Quit** — press ⌘Q or close the preview window.
