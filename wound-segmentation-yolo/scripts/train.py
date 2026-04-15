"""
Train YOLO26-seg on the FUSeg wound dataset.

Defaults are tuned for a single RTX 3090 (24 GB):
  - imgsz=640 to match the iOS export pipeline
  - batch sized to fit comfortably with mixed precision
  - 200 epochs with cosine LR
  - early-stopping patience=30

Run with:
  uv run python scripts/train.py                       # nano (default)
  uv run python scripts/train.py --size s              # small
  uv run python scripts/train.py --size m --device 2   # medium on GPU 2

The script does NOT touch GPU 0 by default (busy A6000). Pick a free GPU
explicitly with --device. Use `nvidia-smi` to check first.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
DATASET_YAML = PROJECT_DIR / "dataset.yaml"
RUNS_DIR = PROJECT_DIR / "runs"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--size", choices=["n", "s", "m", "l", "x"], default="n",
                        help="YOLO26-seg model size (default: n)")
    parser.add_argument("--epochs", type=int, default=200)
    parser.add_argument("--imgsz", type=int, default=512,
                        help="Input size (default 512 = native FUSeg resolution; must be multiple of 32)")
    parser.add_argument("--batch", type=int, default=32,
                        help="Batch size; reduce if you OOM on larger model sizes")
    parser.add_argument("--workers", type=int, default=8,
                        help="DataLoader worker processes per training run")
    parser.add_argument("--device", default="1",
                        help="Physical CUDA device id(s), e.g. '1' or '1,2,3'. Passed directly to Ultralytics.")
    parser.add_argument("--patience", type=int, default=30,
                        help="Early stopping patience in epochs")
    parser.add_argument("--name", default=None,
                        help="Run name (defaults to yolo26{size}-seg-fuseg)")
    parser.add_argument("--resume", action="store_true",
                        help="Resume the most recent run with this name")
    args = parser.parse_args()

    if not DATASET_YAML.exists():
        print(f"error: {DATASET_YAML} not found — run convert_masks_to_yolo.py first", file=sys.stderr)
        return 1

    # Note: do NOT pre-set CUDA_VISIBLE_DEVICES here. Ultralytics' select_device()
    # overwrites it from the `device=` arg (see torch_utils.py:221), undoing any
    # masking. We pass the physical device id directly instead.
    from ultralytics import YOLO  # noqa: E402

    model_name = f"yolo26{args.size}-seg.pt"
    run_name = args.name or f"yolo26{args.size}-seg-fuseg"

    print(f"Loading {model_name}…")
    model = YOLO(model_name)

    print(f"Training on {DATASET_YAML}")
    print(f"  device={args.device}  imgsz={args.imgsz}  batch={args.batch}  epochs={args.epochs}")
    # Parse device string to either an int or a list of ints (for multi-GPU)
    if "," in args.device:
        device_arg: int | list[int] = [int(d) for d in args.device.split(",")]
    else:
        device_arg = int(args.device)

    model.train(
        data=str(DATASET_YAML),
        imgsz=args.imgsz,
        epochs=args.epochs,
        batch=args.batch,
        workers=args.workers,
        patience=args.patience,
        device=device_arg,
        project=str(RUNS_DIR),
        name=run_name,
        exist_ok=args.resume,
        resume=args.resume,
        cos_lr=True,
        amp=True,
        # Augmentation tuned for medical images: keep mosaic but disable
        # extreme color jitter that distorts wound appearance.
        hsv_h=0.01,
        hsv_s=0.4,
        hsv_v=0.3,
        flipud=0.5,
        fliplr=0.5,
        degrees=15.0,
        translate=0.1,
        scale=0.3,
        mosaic=1.0,
        # Ultralytics will save best.pt and last.pt under runs/<name>/weights/
    )

    # Validate the best checkpoint and print metrics
    print("\nValidating best.pt…")
    best_path = RUNS_DIR / run_name / "weights" / "best.pt"
    if best_path.exists():
        best = YOLO(str(best_path))
        metrics = best.val(data=str(DATASET_YAML), imgsz=args.imgsz, device=device_arg)
        print(metrics)
    return 0


if __name__ == "__main__":
    sys.exit(main())
