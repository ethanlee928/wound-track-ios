"""Re-split the Roboflow PI staging dataset by source stem to eliminate
augmentation-based data leakage AND uneven pre-augmentation.

The Roboflow export contains pre-augmented copies named like
`<sourcestem>_jpg.rf.<hash>.jpg`. Two problems:
  1. The default split puts augmented siblings into different splits,
     contaminating validation (data leakage).
  2. Roboflow over-augmented some source images (e.g., one stem has 82 copies)
     while leaving others with just 1, biasing the model heavily toward the
     over-represented wounds.

Fix: group every augmented copy by source stem, perform a class-stratified
random split on stems, then write *exactly one canonical file per stem* to the
output. We pick the lexicographically smallest filename so the choice is
deterministic. YOLO classify will apply augmentation on-the-fly during
training, so we do not need Roboflow's pre-baked augmentations at all.

Output layout:
    pressure-ulcer-cls-clean/
        train/<class>/<one_img_per_stem>
        val/<class>/<one_img_per_stem>
        test/<class>/<one_img_per_stem>
"""

from __future__ import annotations

import argparse
import os
import random
import re
import shutil
import sys
from collections import Counter, defaultdict
from pathlib import Path

import yaml

SPLIT_MAP = {"train": "train", "valid": "val", "test": "test"}
IMG_EXTS = {".jpg", ".jpeg", ".png"}
SOURCE_STEM_RE = re.compile(r"^(.*?)_jpg\.rf\.[0-9a-f]+$")


def source_stem(name: str) -> str:
    stem = Path(name).stem
    m = SOURCE_STEM_RE.match(stem)
    return m.group(1) if m else stem


def first_class_id(label_path: Path) -> int | None:
    try:
        text = label_path.read_text().strip()
    except FileNotFoundError:
        return None
    return int(text.split()[0]) if text else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path,
                        default=Path("pressure-ulcer-staging/pressure-ulcer-1"))
    parser.add_argument("--output", type=Path, default=Path("pressure-ulcer-cls-clean"))
    parser.add_argument("--val-ratio", type=float, default=0.10)
    parser.add_argument("--test-ratio", type=float, default=0.10)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    source = args.source.resolve()
    output = args.output.resolve()
    rng = random.Random(args.seed)

    with (source / "data.yaml").open() as f:
        meta = yaml.safe_load(f)
    class_names: list[str] = meta["names"]
    print(f"Classes: {class_names}")

    # Step 1: walk every image across every original split, group by source stem.
    # Each entry: stem -> {"class": str, "images": [absolute_path, ...]}
    by_stem: dict[str, dict] = {}
    multi_class_stems: list[str] = []

    for src_split in SPLIT_MAP:
        img_dir = source / src_split / "images"
        lbl_dir = source / src_split / "labels"
        if not img_dir.exists():
            continue
        for img_path in sorted(img_dir.iterdir()):
            if img_path.suffix.lower() not in IMG_EXTS:
                continue
            cls_id = first_class_id(lbl_dir / (img_path.stem + ".txt"))
            if cls_id is None or not (0 <= cls_id < len(class_names)):
                continue
            cls_name = class_names[cls_id]
            stem = source_stem(img_path.name)
            entry = by_stem.setdefault(stem, {"class": cls_name, "images": []})
            if entry["class"] != cls_name:
                multi_class_stems.append(stem)
            entry["images"].append(img_path.resolve())

    print(f"Total unique source stems: {len(by_stem)}")
    if multi_class_stems:
        print(f"WARN: {len(set(multi_class_stems))} stems have inconsistent class labels"
              f" across augmentations -- keeping the first seen.")

    # Step 2: stratified split of stems per class
    stems_by_class: dict[str, list[str]] = defaultdict(list)
    for stem, entry in by_stem.items():
        stems_by_class[entry["class"]].append(stem)

    splits: dict[str, list[str]] = {"train": [], "val": [], "test": []}
    for cls_name, stems in stems_by_class.items():
        rng.shuffle(stems)
        n = len(stems)
        n_test = max(1, int(round(n * args.test_ratio)))
        n_val = max(1, int(round(n * args.val_ratio)))
        n_train = n - n_val - n_test
        splits["train"].extend(stems[:n_train])
        splits["val"].extend(stems[n_train:n_train + n_val])
        splits["test"].extend(stems[n_train + n_val:])
        print(f"  {cls_name}: {n} stems -> train={n_train}, val={n_val}, test={n_test}")

    # Step 3: clear any previous output and write ONE symlink per stem
    if output.exists():
        print(f"Removing existing {output}")
        shutil.rmtree(output)

    counts: dict[str, Counter] = defaultdict(Counter)
    for split, stem_list in splits.items():
        for cls_name in class_names:
            (output / split / cls_name).mkdir(parents=True, exist_ok=True)
        for stem in stem_list:
            entry = by_stem[stem]
            cls_name = entry["class"]
            # Pick the lexicographically smallest filename for determinism.
            chosen = sorted(entry["images"], key=lambda p: p.name)[0]
            link = output / split / cls_name / chosen.name
            os.symlink(chosen, link)
            counts[split][cls_name] += 1

    print()
    print(f"Wrote ImageFolder to: {output}")
    for split in ("train", "val", "test"):
        total = sum(counts[split].values())
        print(f"  {split}: {total} images (one per source stem)")
        for cls in class_names:
            print(f"    {cls}: {counts[split][cls]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
