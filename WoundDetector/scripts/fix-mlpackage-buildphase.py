#!/usr/bin/env python3
"""
Post-process xcodegen output to make .mlpackage files compile to .mlmodelc.

xcodegen treats .mlpackage as a generic folder reference and puts it in the
Resources build phase, which copies it as-is. We need:
  1. lastKnownFileType = folder.mlpackage (so Xcode recognizes it as a CoreML model)
  2. PBXBuildFile entries marked "in Sources" (not "in Resources")
  3. PBXBuildFile entries moved into PBXSourcesBuildPhase (not PBXResourcesBuildPhase)

Run this after `xcodegen generate`.
"""

import re
import sys
from pathlib import Path

PBXPROJ = Path(__file__).resolve().parent.parent / "WoundDetector.xcodeproj" / "project.pbxproj"


def main() -> int:
    if not PBXPROJ.exists():
        print(f"error: {PBXPROJ} not found — run xcodegen first", file=sys.stderr)
        return 1

    text = PBXPROJ.read_text()

    # 1. Fix lastKnownFileType for .mlpackage references
    text = re.sub(
        r'(lastKnownFileType = )folder(; name = "[^"]*\.mlpackage";)',
        r"\1folder.mlpackage\2",
        text,
    )

    # 2. Rename "in Resources" → "in Sources" for .mlpackage build files,
    #    and collect their build file IDs so we can move them between phases.
    mlpackage_build_ids: list[str] = []

    def rename_build_file(match: re.Match[str]) -> str:
        mlpackage_build_ids.append(match.group(1))
        return f'{match.group(1)} /* {match.group(2)}.mlpackage in Sources */ = {{isa = PBXBuildFile; fileRef = {match.group(3)} /* {match.group(2)}.mlpackage */; }};'

    text = re.sub(
        r'([0-9A-F]{24}) /\* ([^ ]+)\.mlpackage in Resources \*/ = \{isa = PBXBuildFile; fileRef = ([0-9A-F]{24}) /\* [^ ]+\.mlpackage \*/; \};',
        rename_build_file,
        text,
    )

    if not mlpackage_build_ids:
        print("warning: no .mlpackage build files found — nothing to fix")
        return 0

    # 3. Remove the build file references from PBXResourcesBuildPhase
    def strip_from_resources(match: re.Match[str]) -> str:
        body = match.group(0)
        for build_id in mlpackage_build_ids:
            # Match "<tab><id> /* ... in Sources */," (we already renamed) or "in Resources"
            body = re.sub(
                rf"\s*{build_id} /\* [^*]*\*/,\n",
                "\n",
                body,
            )
        return body

    text = re.sub(
        r"/\* Begin PBXResourcesBuildPhase section \*/.*?/\* End PBXResourcesBuildPhase section \*/",
        strip_from_resources,
        text,
        flags=re.DOTALL,
    )

    # 4. Insert the build file references into the app target's PBXSourcesBuildPhase.
    #    We identify the app target's sources phase by finding the one that contains
    #    WoundDetectorApp.swift.
    def add_to_sources(match: re.Match[str]) -> str:
        block = match.group(0)
        if "WoundDetectorApp.swift" not in block:
            return block
        # Insert the new entries just before the closing ");" of files = (...)
        lines_to_add = "".join(
            f"\t\t\t\t{bid} /* yolo26 mlpackage in Sources */,\n"
            for bid in mlpackage_build_ids
        )
        return re.sub(
            r"(files = \([^)]*?)(\n\t\t\t\);)",
            lambda m: m.group(1) + "\n" + lines_to_add.rstrip("\n") + m.group(2),
            block,
            count=1,
        )

    text = re.sub(
        r"[0-9A-F]{24} /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;.*?\};",
        add_to_sources,
        text,
        flags=re.DOTALL,
    )

    PBXPROJ.write_text(text)
    print(f"fixed {len(mlpackage_build_ids)} .mlpackage references in {PBXPROJ.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
