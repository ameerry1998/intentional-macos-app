#!/usr/bin/env python3
"""
Add the Close-the-Noise feature's new Swift files to the Intentional Xcode project.

Adds:
  - Intentional/AlwaysAllowedList.swift
  - Intentional/MigrationAlwaysAllowed.swift
  - Intentional/SessionStash.swift          (created later by Task 5)
  - Intentional/Sweeper.swift               (created later by Task 6)
  - Intentional/StashInspectorWindow.swift  (created later by Task 11)

This script is idempotent: it skips files that are already referenced.

UUIDs follow the project's A1000XXX pattern. Highest existing prefix was
A1000095 (NudeNetTests, .040). We continue from A1000096 (.041).
"""

import os
import sys

PROJ_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Intentional.xcodeproj",
    "project.pbxproj",
)

# (filename, buildFileUUID, fileRefUUID)
FILES = [
    ("AlwaysAllowedList.swift",     "A1000096000000000000041", "A1000097000000000000041"),
    ("MigrationAlwaysAllowed.swift","A1000098000000000000042", "A1000099000000000000042"),
    ("SessionStash.swift",          "A1000100000000000000043", "A1000101000000000000043"),
    ("Sweeper.swift",               "A1000102000000000000044", "A1000103000000000000044"),
    ("StashInspectorWindow.swift",  "A1000104000000000000045", "A1000105000000000000045"),
    ("StageOneIntentWindow.swift",  "A1000106000000000000046", "A1000107000000000000046"),
    ("SweepBenchmark.swift",        "A1000108000000000000047", "A1000109000000000000047"),
    ("SweepReviewWindow.swift",     "A100010A000000000000048", "A100010B000000000000048"),
]

# Anchor: NudeNetDetector.swift is the most recent Swift add. Insert AFTER it.
ANCHOR_BUILD = "\t\tA1000082000000000000034 /* NudeNetDetector.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1000083000000000000034 /* NudeNetDetector.swift */; };"
ANCHOR_FILEREF = "\t\tA1000083000000000000034 /* NudeNetDetector.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NudeNetDetector.swift; sourceTree = \"<group>\"; };"
ANCHOR_GROUP = "\t\t\t\tA1000083000000000000034 /* NudeNetDetector.swift */,"
ANCHOR_SOURCES = "\t\t\t\tA1000082000000000000034 /* NudeNetDetector.swift in Sources */,"


def main():
    with open(PROJ_PATH, "r") as f:
        content = f.read()

    # Filter out files already referenced (idempotency).
    to_add = [(name, bf, fr) for (name, bf, fr) in FILES if name not in content]
    if not to_add:
        print("All files already in project.pbxproj — nothing to do.")
        return

    print(f"Adding {len(to_add)} file(s) to project.pbxproj:")
    for (name, _, _) in to_add:
        print(f"  + {name}")

    # 1. PBXBuildFile entries
    buildfile_block = "\n".join(
        f"\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {name} */; }};"
        for (name, bf, fr) in to_add
    )
    if ANCHOR_BUILD not in content:
        print(f"ERROR: anchor not found in PBXBuildFile section")
        sys.exit(1)
    content = content.replace(ANCHOR_BUILD, ANCHOR_BUILD + "\n" + buildfile_block)

    # 2. PBXFileReference entries
    fileref_block = "\n".join(
        f"\t\t{fr} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};"
        for (name, _, fr) in to_add
    )
    if ANCHOR_FILEREF not in content:
        print(f"ERROR: anchor not found in PBXFileReference section")
        sys.exit(1)
    content = content.replace(ANCHOR_FILEREF, ANCHOR_FILEREF + "\n" + fileref_block)

    # 3. Group children
    group_block = "\n".join(
        f"\t\t\t\t{fr} /* {name} */,"
        for (name, _, fr) in to_add
    )
    if ANCHOR_GROUP not in content:
        print(f"ERROR: anchor not found in group children")
        sys.exit(1)
    content = content.replace(ANCHOR_GROUP, ANCHOR_GROUP + "\n" + group_block)

    # 4. Sources build phase
    sources_block = "\n".join(
        f"\t\t\t\t{bf} /* {name} in Sources */,"
        for (name, bf, _) in to_add
    )
    if ANCHOR_SOURCES not in content:
        print(f"ERROR: anchor not found in Sources build phase")
        sys.exit(1)
    content = content.replace(ANCHOR_SOURCES, ANCHOR_SOURCES + "\n" + sources_block)

    with open(PROJ_PATH, "w") as f:
        f.write(content)

    print(f"SUCCESS: project.pbxproj updated with {len(to_add)} new file(s).")


if __name__ == "__main__":
    main()
