"""Convert a Roboflow YOLO-detection export into an ImageFolder layout for `yolo classify`.

Each label file is assumed to contain whole-image bboxes (the Roboflow PI staging
dataset is annotated this way — every bbox covers ~the entire image). For each
image, we look at the *first* class id in the label file and place a symlink
under `<output_dir>/<split>/<class_name>/`.

Output layout:
    <output_dir>/
        train/<class_name>/<img>
        val/<class_name>/<img>
        test/<class_name>/<img>

Note: Roboflow uses `valid/` but Ultralytics `yolo classify` expects `val/`.
"""

from __future__ import annotations

import argparse
import os
import sys
from collections import Counter, defaultdict
from pathlib import Path

import yaml

SPLIT_MAP = {"train": "train", "valid": "val", "test": "test"}
IMG_EXTS = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def first_class_id(label_path: Path) -> int | None:
    try:
        text = label_path.read_text().strip()
    except FileNotFoundError:
        return None
    if not text:
        return None
    return int(text.split()[0])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source",
        type=Path,
        default=Path("pressure-ulcer-staging/pressure-ulcer-1"),
        help="Roboflow YOLO-detection export root (contains data.yaml).",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("pressure-ulcer-cls"),
        help="Where to write the ImageFolder layout.",
    )
    args = parser.parse_args()

    source = args.source.resolve()
    output = args.output.resolve()

    data_yaml = source / "data.yaml"
    if not data_yaml.exists():
        print(f"ERROR: missing {data_yaml}", file=sys.stderr)
        return 1
    with data_yaml.open() as f:
        meta = yaml.safe_load(f)
    class_names = meta["names"]
    print(f"Classes: {class_names}")

    counts: dict[str, Counter] = defaultdict(Counter)
    skipped: dict[str, int] = defaultdict(int)

    for src_split, dst_split in SPLIT_MAP.items():
        img_dir = source / src_split / "images"
        lbl_dir = source / src_split / "labels"
        if not img_dir.exists():
            print(f"  (no {src_split}/images, skipping)")
            continue

        for cls_name in class_names:
            (output / dst_split / cls_name).mkdir(parents=True, exist_ok=True)

        for img_path in sorted(img_dir.iterdir()):
            if img_path.suffix.lower() not in IMG_EXTS:
                continue
            label_path = lbl_dir / (img_path.stem + ".txt")
            cls_id = first_class_id(label_path)
            if cls_id is None or cls_id < 0 or cls_id >= len(class_names):
                skipped[dst_split] += 1
                continue
            cls_name = class_names[cls_id]
            link_path = output / dst_split / cls_name / img_path.name
            if link_path.exists() or link_path.is_symlink():
                link_path.unlink()
            os.symlink(img_path, link_path)
            counts[dst_split][cls_name] += 1

    print()
    print("Wrote ImageFolder to:", output)
    for split in ("train", "val", "test"):
        if not counts[split]:
            continue
        total = sum(counts[split].values())
        print(f"  {split}: {total} images" + (f" ({skipped[split]} skipped)" if skipped[split] else ""))
        for cls in class_names:
            print(f"    {cls}: {counts[split][cls]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
