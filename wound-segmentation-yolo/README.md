# wound-segmentation-yolo

Training pipeline for the two model families bundled in **WoundTrack**:

1. **Wound segmentation** (PGIE) — YOLO26-seg fine-tuned on the [AZH FUSeg](https://fusc.grand-challenge.org/) foot-ulcer dataset.
2. **Pressure-injury staging** (SGIE) — YOLO26-cls fine-tuned on a Roboflow PI-staging dataset (4 stages).

This repo lives separately from the iOS app because training happens on a remote GPU server. Only the **code** and **configs** are version-controlled here — datasets, weights, logs, and the venv stay on the server. Trained `.pt` checkpoints are scp'd back into `model-export/` and exported to CoreML there.

---

## Layout

```
wound-segmentation-yolo/
├── pyproject.toml          # uv project (cu126 torch + ultralytics + roboflow)
├── uv.lock
├── dataset.yaml            # FUSeg seg config (single-class: wound)
└── scripts/
    ├── download_roboflow.py        # pull PI-staging dataset from Roboflow
    ├── convert_masks_to_yolo.py    # FUSeg binary masks → YOLO polygon labels
    ├── yolo_det_to_imagefolder.py  # detection labels → ImageFolder for cls
    ├── build_clean_split.py        # leakage-free train/val/test split for cls
    ├── train.py                    # YOLO26-seg training (FUSeg)
    └── train_classifier.py         # YOLO26-cls training (PI-staging)
```

Excluded from git (see root `.gitignore`):

- `.venv/`
- `runs/` — all training outputs and weights
- `*.pt` — checkpoints
- `dataset/`, `pressure-ulcer-cls*/`, `pressure-ulcer-staging/` — datasets (licensing + size)
- `logs/`, `*.npy`, `.env`

---

## Setup (on a CUDA box)

```bash
cd wound-segmentation-yolo
uv sync
```

For the staging dataset download, set a Roboflow key:

```bash
echo "ROBOFLOW_API_KEY=<your-key>" > .env
```

---

## Pipeline 1 — Wound segmentation (FUSeg)

Pull FUSeg manually from the [grand-challenge release](https://fusc.grand-challenge.org/) into `dataset/` (it is gated, so no automated download). Then convert the binary RGB masks to YOLO polygon labels:

```bash
uv run python scripts/convert_masks_to_yolo.py
```

This walks each mask, extracts external contours via OpenCV `findContours`, simplifies them with Douglas-Peucker, drops noise (<0.01% area), and writes one normalized polygon per line into `dataset/labels/{train,val}/`. Images are symlinked, not copied.

Train:

```bash
uv run python scripts/train.py --size n --device 1   # nano
uv run python scripts/train.py --size s --device 2   # small
uv run python scripts/train.py --size m --device 3   # medium
```

Defaults: `imgsz=512` (native FUSeg), `batch=32`, `epochs=200`, `patience=30`, cosine LR, AMP, medical-friendly augmentation (mosaic + flips + small rotations, no extreme color jitter). Best/last checkpoints land in `runs/yolo26{n,s,m}-seg-fuseg/weights/`.

**Caveat — GPU pinning:** do **not** pre-set `CUDA_VISIBLE_DEVICES`. Ultralytics' `select_device()` overwrites it from `device=`, silently colliding parallel runs onto the same physical GPU. Pass the physical device id directly (`--device 2`).

Results (from the runs that shipped):

| Variant | mAP50 (mask) | mAP50-95 | Notes |
|---|---|---|---|
| `yolo26n-seg` | 0.896 | 0.596 | shipped |
| `yolo26s-seg` | 0.897 | 0.608 | shipped |
| `yolo26m-seg` | 0.872 | 0.571 | overfit on 810 training images — **discarded** |

Nano and Small converged to nearly identical accuracy → dataset ceiling, not capacity ceiling. Smaller-is-better on this dataset.

---

## Pipeline 2 — Pressure-injury staging (SGIE)

Download the Roboflow PI-staging detection dataset:

```bash
uv run python scripts/download_roboflow.py
```

Convert YOLO detection labels → ImageFolder (one image per stage label, cropped to the wound bbox):

```bash
uv run python scripts/yolo_det_to_imagefolder.py
```

Build a leakage-free train/val/test split (groups crops by source image stem so the same wound never appears across splits):

```bash
uv run python scripts/build_clean_split.py
```

Train:

```bash
uv run python scripts/train_classifier.py --size n --device 1
uv run python scripts/train_classifier.py --size s --device 2
```

Defaults: `imgsz=224` (YOLO26-cls native), `batch=64`, `epochs=100`, `patience=20`. Class balance is skewed (stage1+stage4 ~12% each, stage3 ~47%) — monitor per-class accuracy alongside top-1.

The shipped placeholder is `yolo26n-cls` at ~75.8% test accuracy. The slot is reserved for a stronger DFUC-2021 infection/ischaemia classifier when dataset access lands.

---

## Export back to the app

After training, copy the best checkpoint to your local mac and export to CoreML in `model-export/`:

```bash
# on the GPU server
scp runs/yolo26n-seg-fuseg/weights/best.pt mac:~/.../model-export/wound-yolo26n-seg.pt

# on the mac
cd model-export
uv run yolo export model=wound-yolo26n-seg.pt format=coreml imgsz=512 nms=False
cp -R wound-yolo26n-seg.mlpackage ../WoundTrack/Resources/
```

See the root [`README.md`](../README.md) for the rest of the iOS build pipeline.
