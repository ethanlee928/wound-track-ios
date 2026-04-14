# WoundTrack

On-device wound segmentation iOS app powered by **YOLO26-seg** running through CoreML. Final project for **ELEG5600 (CUHK)**.

The app lets a user pick or capture a photo, runs instance segmentation entirely on-device, and overlays the predicted wound mask. It bundles five model variants — three pretrained COCO baselines plus two fine-tuned wound-specific models — selectable from a two-dimensional picker (task × size).

---

## Features

- **On-device inference** — no network round-trips, no PHI leaving the phone
- **Five bundled YOLO26-seg variants** — General × {Nano, Small, Medium}, Wound × {Nano, Small}
- **Two-row model picker** — Task selector (General COCO / Wound FUSeg) + Size selector (N / S / M)
- **Camera + photo library** input flows
- **EXIF-aware orientation handling** so portrait camera photos aren't rotated during inference
- **Async model loading** with persistence — last-used variant restored on launch
- **Save / share** annotated results

---

## Architecture

```
final-project/
├── WoundTrack/        # SwiftUI iOS app (xcodegen-driven)
└── model-export/         # Python uv project for CoreML export
```

The two components are loosely coupled:

1. **`model-export/`** turns Ultralytics `.pt` checkpoints into CoreML `.mlpackage` files at the right input resolution.
2. **`WoundTrack/`** bundles those `.mlpackage` files as build resources, compiles them to `.mlmodelc` at build time, and loads them on-device via the `YOLO` Swift package.

Training itself happens outside this repo on a GPU server — only the resulting checkpoints flow back here.

---

## Bundled models

| Variant | Task | Backbone | Params | Training data | mAP50 (mask) | `.mlpackage` |
|---|---|---|---|---|---|---|
| `yolo26n-seg` | General | YOLO26-N | 3.0 M | COCO | — (baseline) | ~5 MB |
| `yolo26s-seg` | General | YOLO26-S | 11.4 M | COCO | — (baseline) | ~20 MB |
| `yolo26m-seg` | General | YOLO26-M | 27.0 M | COCO | — (baseline) | ~50 MB |
| **`wound-yolo26n-seg`** | **Wound** | YOLO26-N | 3.0 M | AZH/FUSeg | **0.896** | **~5 MB** |
| **`wound-yolo26s-seg`** | **Wound** | YOLO26-S | 11.4 M | AZH/FUSeg | **0.897** | **~20 MB** |

The wound variants are fine-tuned on the [AZH FUSeg](https://fusc.grand-challenge.org/) (Foot Ulcer Segmentation) dataset — 810 train + 200 val images, single-class binary segmentation.

The **medium wound variant was trained but discarded**: it overfit on the small dataset (mAP50 0.872, lower than nano/small) and inference is slower. Smaller models won here, which is itself a useful finding for the final report.

---

## Project structure

```
WoundTrack/
├── project.yml                          # xcodegen source of truth
├── Info.plist                           # camera/photo library usage strings
├── Sources/
│   ├── WoundTrackApp.swift              # @main entry
│   ├── ContentView.swift                # main screen layout
│   ├── DetectionViewModel.swift         # model loading + inference orchestration
│   ├── ModelVariant.swift               # 5-case enum, Task × Size
│   ├── ModelPickerView.swift            # two-row segmented picker
│   ├── WoundStage.swift                 # NPIAP staging enum (for future staging model)
│   ├── WoundInfoPanel.swift             # detection result list
│   ├── ImagePicker.swift                # UIImagePickerController wrapper (camera)
│   ├── PhotoLibraryPicker.swift         # PHPickerViewController wrapper (library)
│   └── ShareSheet.swift                 # UIActivityViewController wrapper
├── Tests/
│   └── WoundStageTests.swift            # XCTest for class-label parsing
├── Resources/                           # *.mlpackage files (gitignored)
└── scripts/
    └── fix-mlpackage-buildphase.py      # post-process generated pbxproj

model-export/
├── pyproject.toml                       # uv project, ultralytics + coremltools
├── uv.lock
└── main.py
```

---

## Setup

### Prerequisites

- macOS with Xcode 16+
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [`uv`](https://github.com/astral-sh/uv) (`brew install uv`)
- An iPhone for on-device testing (CoreML doesn't run in the simulator for these models)

### Recover the model artifacts

The `.pt` and `.mlpackage` files are intentionally not in git (binary artifacts). Recover them before building:

```bash
cd model-export
uv sync

# COCO baseline models — auto-downloads .pt and exports to CoreML
uv run yolo export model=yolo26n-seg.pt format=coreml imgsz=640
uv run yolo export model=yolo26s-seg.pt format=coreml imgsz=640
uv run yolo export model=yolo26m-seg.pt format=coreml imgsz=640

# Wound-fine-tuned models — copy the trained .pt back from training server first,
# then export at the native FUSeg resolution (imgsz=512).
# Place wound-yolo26n-seg.pt and wound-yolo26s-seg.pt in model-export/, then:
uv run yolo export model=wound-yolo26n-seg.pt format=coreml imgsz=512
uv run yolo export model=wound-yolo26s-seg.pt format=coreml imgsz=512

# Move the exports into the iOS app's resources
cp -R wound-yolo26n-seg.mlpackage   ../WoundTrack/Resources/
cp -R wound-yolo26s-seg.mlpackage   ../WoundTrack/Resources/
cp -R yolo26n-seg.mlpackage         ../WoundTrack/Resources/
cp -R yolo26s-seg.mlpackage         ../WoundTrack/Resources/
cp -R yolo26m-seg.mlpackage         ../WoundTrack/Resources/
```

### Build the iOS app

```bash
cd WoundTrack
xcodegen generate
python3 scripts/fix-mlpackage-buildphase.py
open WoundTrack.xcodeproj
```

In Xcode, set your development team under **Signing & Capabilities**, then build and run on a connected iPhone.

---

## Training pipeline

The wound models were trained on the [AZH FUSeg](https://fusc.grand-challenge.org/) dataset (810 train / 200 val, 512×512 binary masks).

High-level pipeline:

1. **Mask → polygon conversion**: AZH ships binary RGB masks; YOLO segmentation expects polygon contours. A converter walks each mask, extracts external contours via OpenCV `findContours`, simplifies them with Douglas-Peucker (`approxPolyDP`), drops noise (<0.01% area), and writes one normalized polygon per line in the YOLO `.txt` format.
2. **Symlinked dataset structure**: images are symlinked (not copied) into the YOLO `images/{train,val}/` layout to avoid duplication.
3. **`dataset.yaml`**: single-class config (`0: wound`).
4. **Training**: `yolo26{n,s,m}-seg.pt` fine-tuned for up to 200 epochs with `patience=30` early stopping, `imgsz=512` (native FUSeg resolution to avoid resize), batch=32, mixed precision, cosine LR.
5. **Augmentation**: tuned for medical images — disabled extreme color jitter (`hsv_s=0.4`, `hsv_v=0.3`), kept mosaic + flips + small rotations.

### Results

| Variant | Epochs (early-stopped) | Best mAP50 (M) | Best mAP50-95 (M) | Per-epoch | Inference (ms/image, 3090) |
|---|---|---|---|---|---|
| `yolo26n-seg` | 182 / 200 | **0.896** | 0.596 | ~8 s | 2.6 |
| `yolo26s-seg` | 180 / 200 | **0.897** | 0.608 | ~10 s | 3.3 |
| `yolo26m-seg` | 66 / 200 | 0.872 | 0.571 | ~16 s | 5.7 |

Nano and Small converged to nearly identical accuracy, suggesting we hit a dataset ceiling rather than a capacity ceiling. Medium underperformed — almost certainly overfitting on 810 training images.

---

## Key technical decisions

These are the decisions worth remembering for the final report:

### 1. Native 512×512 inference

The FUSeg dataset is uniformly 512×512. We train *and* export at `imgsz=512`, which:

- Avoids any resize during inference
- Keeps the model input shape divisible by the YOLO stride (32)
- Reduces inference cost ~1.5× vs the default 640 (cost scales with H × W)
- Means a smaller, faster, more accurate on-device model

The Swift `YOLO` package automatically reads the model's input shape from CoreML metadata, so no app code changes are needed when switching between 512 and 640.

### 2. xcodegen + post-process script for `.mlpackage`

`xcodegen` treats `.mlpackage` as a generic folder reference and puts it in the **Resources** build phase. That's wrong: Xcode just copies the folder verbatim instead of compiling it to `.mlmodelc`.

The fix is **`scripts/fix-mlpackage-buildphase.py`**, run after `xcodegen generate`. It patches the generated `pbxproj` to:

- Set `lastKnownFileType = folder.mlpackage` so Xcode recognizes it as a CoreML model
- Move the `PBXBuildFile` references from `PBXResourcesBuildPhase` to `PBXSourcesBuildPhase` so they're compiled to `.mlmodelc` at build time

This is the only step in the build pipeline that isn't expressible in `project.yml`.

### 3. Two-row model picker

Earlier iterations used a single segmented picker with N/S/M, but adding the wound variants made the design two-dimensional (Task × Size). Rather than cramming five buttons into one row, the picker is now:

- **Row 1** (Task): segmented `[General | Wound]`
- **Row 2** (Size): segmented `[N | S | M]` — *dynamically* shows only sizes that exist for the current task

When the user switches task, the picker tries to keep the current size (e.g. switching from `General · Small` to `Wound · Small`), falling back to nano if not available. The size segment for "M" disappears entirely when in Wound mode rather than being greyed out.

### 4. EXIF orientation normalization

Camera photos on iOS have an `imageOrientation` field (often `.right` for portrait shots). UIKit respects this for *display*, but Vision/CoreML processes the raw pixel buffer and ignores the metadata — so the model sees a sideways image.

`DetectionViewModel.runInference(on:)` calls a `UIImage.normalizedOrientation()` extension that re-draws the image with `.up` orientation, baking the rotation into the pixel data before handing it to the model. Without this, every portrait photo gets segmented sideways.

### 5. Strong reference during async model load

The `YOLO` initializer returns synchronously but does its CoreML compilation on a background thread, calling a completion handler. Inside that handler the `[weak self]` capture means the `YOLO` instance has nothing else holding it alive — and gets deallocated mid-compile, silently failing to load.

The fix is to immediately store the returned instance into `self.model` *before* the completion fires:

```swift
let yolo = YOLO(variant.rawValue, task: .segment) { [weak self] result in ... }
self.model = yolo  // strong ref keeps it alive through async compilation
```

### 6. CoreML export environment pinning

A clean install of `coremltools 9.0` produces this cryptic error during YOLO export:

```
TypeError: only 0-dimensional arrays can be converted to Python scalars
```

This is [apple/coremltools#2633](https://github.com/apple/coremltools/issues/2633): newer NumPy and torch versions broke the converter. The fix is to pin in `pyproject.toml`:

```toml
"torch>=2.7.0,<2.8.0",            # coremltools 9.0 only supports torch ≤ 2.7
"torchvision>=0.22.0,<0.23.0",
"numpy<2.4.0",                    # numpy 2.4+ broke array→scalar coercion
```

### 7. Ultralytics `device=` overrides `CUDA_VISIBLE_DEVICES`

When launching parallel training runs on different GPUs, the obvious approach is to set `os.environ["CUDA_VISIBLE_DEVICES"] = "2"` before importing torch, then pass `device=0` to ultralytics. **This silently fails**: `ultralytics/utils/torch_utils.py:select_device()` *overwrites* `CUDA_VISIBLE_DEVICES` with whatever you pass in `device=`, so two parallel runs both end up on physical GPU 0.

The fix is to **not touch `CUDA_VISIBLE_DEVICES` in our code at all** and just pass the physical device id directly to ultralytics: `device=2`. Verified by checking `nvidia-smi` for two distinct PIDs on two distinct GPUs after launching.

### 8. YOLO26 NMS-free format auto-detection

YOLO26's headline architecture change is **end-to-end NMS** baked into the model graph. Exporting with the default `nms=True` produces a CoreML model where post-processing is part of the model itself. The fork of `yolo-ios-app` we depend on auto-detects this from the model's CoreML metadata (`userDefined["nms"]`) and skips its own post-NMS step. So switching from YOLOv8 to YOLO26 required **zero Swift code changes** — the package handled it.

---

## Credits

- **Models**: [Ultralytics YOLO26](https://docs.ultralytics.com/models/yolo26/) (segmentation variants)
- **iOS Swift package**: forked from [`ultralytics/yolo-ios-app`](https://github.com/ultralytics/yolo-ios-app) → [`ethanlee928/yolo-ios-app`](https://github.com/ethanlee928/yolo-ios-app)
- **Wound dataset**: [AZH FUSeg](https://fusc.grand-challenge.org/) — Wang et al., *Fully automatic wound segmentation with deep convolutional neural networks*, Scientific Reports 10, 21897 (2020)
- **Build tooling**: [`xcodegen`](https://github.com/yonaskolb/XcodeGen), [`uv`](https://github.com/astral-sh/uv)
