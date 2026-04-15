"""
Convert AZH/FUSeg binary wound masks into YOLO segmentation format.

Input layout (read-only):
    <SRC>/train/images/*.png       (RGB)
    <SRC>/train/labels/*.png       (binary mask, 0 = background, >0 = wound)
    <SRC>/validation/images/*.png
    <SRC>/validation/labels/*.png

Output layout (created under <DST>):
    <DST>/images/train/*.png       (symlinks to source images)
    <DST>/images/val/*.png         (symlinks)
    <DST>/labels/train/*.txt       (YOLO polygon labels)
    <DST>/labels/val/*.txt

YOLO segmentation label format:
    <class_id> x1 y1 x2 y2 ... xn yn   (normalized 0..1, one polygon per line)

For each binary mask we extract external contours via OpenCV, simplify them
slightly (Douglas-Peucker), drop tiny noise contours, and write each contour
as a separate line — Ultralytics treats multiple lines per file as multiple
instances, which is correct (e.g. multi-wound images).
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

import cv2
import numpy as np

# Drop contours with fewer than this many vertices after approximation
MIN_POLY_POINTS = 3
# Drop contours whose area is less than this fraction of the image area
MIN_AREA_FRAC = 1e-4
# Douglas-Peucker epsilon as a fraction of the contour perimeter
APPROX_EPS_FRAC = 0.002


def mask_to_polygons(mask: np.ndarray) -> list[list[tuple[float, float]]]:
    """Extract normalized polygon contours from a binary mask.

    Returns a list of polygons; each polygon is a list of (x, y) in [0, 1].
    """
    h, w = mask.shape[:2]
    if mask.ndim == 3:
        # Convert RGB mask to single channel — labels are saved as RGB but
        # encode binary information.
        mask = cv2.cvtColor(mask, cv2.COLOR_BGR2GRAY)
    # Binarize: anything above 0 becomes wound. Source uses 0/255.
    binary = (mask > 0).astype(np.uint8) * 255

    contours, _ = cv2.findContours(binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    img_area = float(h * w)
    polygons: list[list[tuple[float, float]]] = []
    for contour in contours:
        area = cv2.contourArea(contour)
        if area / img_area < MIN_AREA_FRAC:
            continue
        # Simplify polygon to keep label files small without sacrificing shape
        eps = APPROX_EPS_FRAC * cv2.arcLength(contour, closed=True)
        approx = cv2.approxPolyDP(contour, eps, closed=True)
        if len(approx) < MIN_POLY_POINTS:
            continue
        normalized = [
            (float(pt[0][0]) / w, float(pt[0][1]) / h) for pt in approx
        ]
        polygons.append(normalized)
    return polygons


def write_yolo_label(label_path: Path, polygons: list[list[tuple[float, float]]], class_id: int = 0) -> None:
    lines: list[str] = []
    for poly in polygons:
        coords = " ".join(f"{x:.6f} {y:.6f}" for x, y in poly)
        lines.append(f"{class_id} {coords}")
    label_path.write_text("\n".join(lines) + ("\n" if lines else ""))


def link_or_copy(src: Path, dst: Path, copy: bool) -> None:
    if dst.exists() or dst.is_symlink():
        dst.unlink()
    if copy:
        shutil.copy2(src, dst)
    else:
        dst.symlink_to(src.resolve())


def convert_split(
    src_images: Path,
    src_labels: Path,
    dst_images: Path,
    dst_labels: Path,
    copy_images: bool,
) -> tuple[int, int]:
    dst_images.mkdir(parents=True, exist_ok=True)
    dst_labels.mkdir(parents=True, exist_ok=True)

    images = sorted(p for p in src_images.iterdir() if p.suffix.lower() in {".png", ".jpg", ".jpeg"})
    converted = 0
    skipped_no_label = 0
    skipped_empty = 0
    for img_path in images:
        label_src = src_labels / img_path.name
        if not label_src.exists():
            skipped_no_label += 1
            continue
        mask = cv2.imread(str(label_src), cv2.IMREAD_UNCHANGED)
        if mask is None:
            skipped_no_label += 1
            continue
        polygons = mask_to_polygons(mask)

        # Symlink/copy the image into the YOLO dataset structure
        link_or_copy(img_path, dst_images / img_path.name, copy_images)
        # Write the label file (may be empty if no wound found, which Ultralytics
        # treats as a background image — that's fine and useful for negatives)
        write_yolo_label((dst_labels / img_path.stem).with_suffix(".txt"), polygons)
        if not polygons:
            skipped_empty += 1
        converted += 1
    return converted, skipped_empty


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--src",
        type=Path,
        default=Path("/home/ethanlee/wound-segmentation/data/Foot Ulcer Segmentation Challenge"),
        help="Source FUSeg dataset root",
    )
    parser.add_argument(
        "--dst",
        type=Path,
        default=Path("/home/ethanlee/wound-segmentation-yolo/dataset"),
        help="Output YOLO dataset root",
    )
    parser.add_argument(
        "--copy",
        action="store_true",
        help="Copy images instead of symlinking (slower, uses more disk)",
    )
    args = parser.parse_args()

    if not args.src.is_dir():
        print(f"error: source {args.src} not found", file=sys.stderr)
        return 1

    splits = [
        ("train", "train", "train"),
        ("validation", "val", "val"),
    ]

    for src_split, dst_split, label_name in splits:
        src_images = args.src / src_split / "images"
        src_labels = args.src / src_split / "labels"
        if not src_images.is_dir() or not src_labels.is_dir():
            print(f"warning: skipping {src_split} (missing images or labels dir)")
            continue
        dst_images = args.dst / "images" / dst_split
        dst_labels = args.dst / "labels" / dst_split
        n, empty = convert_split(src_images, src_labels, dst_images, dst_labels, args.copy)
        print(f"{src_split}: converted {n} images ({empty} had no detected wound polygons)")

    print(f"\nDataset ready at: {args.dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
