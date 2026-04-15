"""
Train YOLO26-cls on the Roboflow pressure-injury staging dataset.

Defaults are tuned for one GPU + a dataset of ~3.8k pre-augmented images
(~620 unique source images, 4 stages). Mirrors the seg training script
conventions for consistency.

Run with:
  uv run python scripts/train_classifier.py                       # nano (default)
  uv run python scripts/train_classifier.py --size s              # small
  uv run python scripts/train_classifier.py --size m --device 2   # medium on GPU 2

Notes:
  * The dataset path must point at an ImageFolder layout with train/val/test
    subdirs. We use the leakage-free clean split produced by build_clean_split.py.
  * imgsz defaults to 224 (YOLO26-cls native).
  * Class balance is skewed (stage1+stage4 ~12% each, stage3 ~47% by source
    stem). Consider monitoring per-class accuracy in addition to top-1.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = PROJECT_DIR / "pressure-ulcer-cls-clean"
RUNS_DIR = PROJECT_DIR / "runs"


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--size", choices=["n", "s", "m", "l", "x"], default="n",
                        help="YOLO26-cls model size (default: n)")
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--imgsz", type=int, default=224,
                        help="Input size (224 = YOLO26-cls native)")
    parser.add_argument("--batch", type=int, default=64)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--device", default="1",
                        help="Physical CUDA device id(s), e.g. 1 or 1,2.")
    parser.add_argument("--patience", type=int, default=20,
                        help="Early stopping patience in epochs")
    parser.add_argument("--data", type=Path, default=DATA_DIR,
                        help="ImageFolder root (must contain train/ and val/)")
    parser.add_argument("--name", default=None,
                        help="Run name (defaults to yolo26{size}-cls-pressure)")
    parser.add_argument("--resume", action="store_true")
    # Augmentation + LR knobs (defaults match the original v1 run; pass these
    # to push past the v1 71% test-acc plateau).
    parser.add_argument("--degrees", type=float, default=15.0)
    parser.add_argument("--scale", type=float, default=0.2)
    parser.add_argument("--translate", type=float, default=0.1)
    parser.add_argument("--mixup", type=float, default=0.0)
    parser.add_argument("--erasing", type=float, default=0.25)
    parser.add_argument("--hsv-h", type=float, default=0.01)
    parser.add_argument("--hsv-s", type=float, default=0.4)
    parser.add_argument("--hsv-v", type=float, default=0.3)
    parser.add_argument("--lr0", type=float, default=None,
                        help="Override initial LR (Ultralytics default if unset)")
    parser.add_argument("--no-cos-lr", action="store_true",
                        help="Disable cosine LR schedule (use flat LR instead)")
    args = parser.parse_args()

    if not (args.data / "train").is_dir() or not (args.data / "val").is_dir():
        print(f"error: expected ImageFolder at {args.data} with train/ and val/", file=sys.stderr)
        print("       run scripts/build_clean_split.py first.", file=sys.stderr)
        return 1

    # Same caveat as train.py: do NOT pre-set CUDA_VISIBLE_DEVICES.
    from ultralytics import YOLO  # noqa: E402

    model_name = f"yolo26{args.size}-cls.pt"
    run_name = args.name or f"yolo26{args.size}-cls-pressure"

    print(f"Loading {model_name}…")
    model = YOLO(model_name)

    if "," in args.device:
        device_arg: int | list[int] = [int(d) for d in args.device.split(",")]
    else:
        device_arg = int(args.device)

    print(f"Training on {args.data}")
    print(f"  device={args.device}  imgsz={args.imgsz}  batch={args.batch}  epochs={args.epochs}")

    train_kwargs = dict(
        task="classify",
        data=str(args.data),
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
        cos_lr=not args.no_cos_lr,
        amp=True,
        # Augmentation: medical images, keep flips + mild color jitter,
        # avoid heavy mosaic (irrelevant for classification).
        hsv_h=args.hsv_h,
        hsv_s=args.hsv_s,
        hsv_v=args.hsv_v,
        flipud=0.5,
        fliplr=0.5,
        degrees=args.degrees,
        translate=args.translate,
        scale=args.scale,
        mixup=args.mixup,
        erasing=args.erasing,
    )
    if args.lr0 is not None:
        train_kwargs["lr0"] = args.lr0
    model.train(**train_kwargs)

    print("\nValidating best.pt on the held-out test split…")
    best_path = RUNS_DIR / run_name / "weights" / "best.pt"
    if best_path.exists() and (args.data / "test").is_dir():
        best = YOLO(str(best_path))
        metrics = best.val(
            data=str(args.data),
            split="test",
            imgsz=args.imgsz,
            device=device_arg,
        )
        print(metrics)
    return 0


if __name__ == "__main__":
    sys.exit(main())
