"""Download the Roboflow pressure ulcer staging dataset for YOLO classification training.

Source: https://universe.roboflow.com/pressure-injury-cy8vo/pressure-ulcer-fr7kn-m0rkf
Format: "folder" -> ImageFolder layout consumed by `yolo classify train`.

Reads ROBOFLOW_API_KEY from .env in the project root.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from roboflow import Roboflow

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT_DIR = PROJECT_ROOT / "pressure-ulcer-staging"

WORKSPACE = "pressure-injury-cy8vo"
PROJECT = "pressure-ulcer-fr7kn-m0rkf"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--version",
        type=int,
        default=1,
        help="Roboflow dataset version (default: 1)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help=f"Where to put the dataset (default: {DEFAULT_OUTPUT_DIR})",
    )
    parser.add_argument(
        "--format",
        default="folder",
        help="Roboflow export format (default: folder)",
    )
    args = parser.parse_args()

    load_dotenv(PROJECT_ROOT / ".env")
    api_key = os.environ.get("ROBOFLOW_API_KEY")
    if not api_key:
        print("ERROR: ROBOFLOW_API_KEY missing from .env", file=sys.stderr)
        return 1

    args.output_dir.mkdir(parents=True, exist_ok=True)
    # Roboflow downloads into the current working directory by default,
    # so chdir to keep things tidy.
    os.chdir(args.output_dir)

    print(f"Roboflow workspace: {WORKSPACE}")
    print(f"Roboflow project:   {PROJECT}")
    print(f"Version:            {args.version}")
    print(f"Format:             {args.format}")
    print(f"Output dir:         {args.output_dir}")

    rf = Roboflow(api_key=api_key)
    project = rf.workspace(WORKSPACE).project(PROJECT)
    version = project.version(args.version)
    dataset = version.download(args.format)

    print()
    print(f"Downloaded to: {dataset.location}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
