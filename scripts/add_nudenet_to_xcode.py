#!/usr/bin/env python3
"""
Add NudeNetDetector.swift and NudeNetV3.mlpackage to the Intentional Xcode project.

This script modifies project.pbxproj to add:
1. PBXFileReference entries for both files
2. PBXBuildFile entries for both files (in Sources phase)
3. Both files to the Intentional group's children list
4. Both files to the Intentional target's Sources build phase
"""

import sys
import os

PROJ_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Intentional.xcodeproj",
    "project.pbxproj",
)

# UUIDs — following the project's A1000XXX pattern, continuing from 033 (OpenNSFW)
# NudeNetDetector.swift
NUDENET_SWIFT_BUILDFILE_ID = "A1000082000000000000034"  # PBXBuildFile
NUDENET_SWIFT_FILEREF_ID   = "A1000083000000000000034"  # PBXFileReference

# NudeNetV3.mlpackage
NUDENET_MODEL_BUILDFILE_ID = "A1000084000000000000035"  # PBXBuildFile
NUDENET_MODEL_FILEREF_ID   = "A1000085000000000000035"  # PBXFileReference


def main():
    with open(PROJ_PATH, "r") as f:
        content = f.read()

    # --- Verify UUIDs don't already exist ---
    for uid in [
        NUDENET_SWIFT_BUILDFILE_ID,
        NUDENET_SWIFT_FILEREF_ID,
        NUDENET_MODEL_BUILDFILE_ID,
        NUDENET_MODEL_FILEREF_ID,
    ]:
        if uid in content:
            print(f"ERROR: UUID {uid} already exists in project.pbxproj")
            sys.exit(1)

    # --- Verify files aren't already referenced ---
    if "NudeNetDetector.swift" in content:
        print("ERROR: NudeNetDetector.swift is already in project.pbxproj")
        sys.exit(1)
    if "NudeNetV3.mlpackage" in content:
        print("ERROR: NudeNetV3.mlpackage is already in project.pbxproj")
        sys.exit(1)

    # =========================================================================
    # 1. Add PBXBuildFile entries (after OpenNSFW.mlmodel build file entry)
    # =========================================================================
    anchor_buildfile = (
        '\t\tA1000081000000000000033 /* OpenNSFW.mlmodel in Sources */ = '
        '{isa = PBXBuildFile; fileRef = A1000080000000000000033 /* OpenNSFW.mlmodel */; };'
    )
    new_buildfiles = (
        anchor_buildfile + "\n"
        "\t\t" + NUDENET_SWIFT_BUILDFILE_ID + " /* NudeNetDetector.swift in Sources */ = "
        "{isa = PBXBuildFile; fileRef = " + NUDENET_SWIFT_FILEREF_ID + " /* NudeNetDetector.swift */; };\n"
        "\t\t" + NUDENET_MODEL_BUILDFILE_ID + " /* NudeNetV3.mlpackage in Sources */ = "
        "{isa = PBXBuildFile; fileRef = " + NUDENET_MODEL_FILEREF_ID + " /* NudeNetV3.mlpackage */; };"
    )
    if anchor_buildfile not in content:
        print("ERROR: Could not find OpenNSFW.mlmodel PBXBuildFile anchor line")
        sys.exit(1)
    content = content.replace(anchor_buildfile, new_buildfiles)

    # =========================================================================
    # 2. Add PBXFileReference entries (after OpenNSFW.mlmodel file ref)
    # =========================================================================
    anchor_fileref = (
        '\t\tA1000080000000000000033 /* OpenNSFW.mlmodel */ = '
        '{isa = PBXFileReference; lastKnownFileType = file.mlmodel; '
        'path = OpenNSFW.mlmodel; sourceTree = "<group>"; };'
    )
    new_filerefs = (
        anchor_fileref + "\n"
        "\t\t" + NUDENET_SWIFT_FILEREF_ID + " /* NudeNetDetector.swift */ = "
        '{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
        'path = NudeNetDetector.swift; sourceTree = "<group>"; };\n'
        "\t\t" + NUDENET_MODEL_FILEREF_ID + " /* NudeNetV3.mlpackage */ = "
        '{isa = PBXFileReference; lastKnownFileType = folder.mlpackage; '
        'path = NudeNetV3.mlpackage; sourceTree = "<group>"; };'
    )
    if anchor_fileref not in content:
        print("ERROR: Could not find OpenNSFW.mlmodel PBXFileReference anchor line")
        sys.exit(1)
    content = content.replace(anchor_fileref, new_filerefs)

    # =========================================================================
    # 3. Add to Intentional group's children (after OpenNSFW.mlmodel)
    # =========================================================================
    anchor_group = "\t\t\t\tA1000080000000000000033 /* OpenNSFW.mlmodel */,"
    new_group = (
        anchor_group + "\n"
        "\t\t\t\t" + NUDENET_SWIFT_FILEREF_ID + " /* NudeNetDetector.swift */,\n"
        "\t\t\t\t" + NUDENET_MODEL_FILEREF_ID + " /* NudeNetV3.mlpackage */,"
    )
    if anchor_group not in content:
        print("ERROR: Could not find OpenNSFW.mlmodel in group children")
        sys.exit(1)
    content = content.replace(anchor_group, new_group)

    # =========================================================================
    # 4. Add to Sources build phase (after OpenNSFW.mlmodel in Sources)
    # =========================================================================
    anchor_sources = "\t\t\t\tA1000081000000000000033 /* OpenNSFW.mlmodel in Sources */,"
    new_sources = (
        anchor_sources + "\n"
        "\t\t\t\t" + NUDENET_SWIFT_BUILDFILE_ID + " /* NudeNetDetector.swift in Sources */,\n"
        "\t\t\t\t" + NUDENET_MODEL_BUILDFILE_ID + " /* NudeNetV3.mlpackage in Sources */,"
    )
    if anchor_sources not in content:
        print("ERROR: Could not find OpenNSFW.mlmodel in Sources build phase")
        sys.exit(1)
    content = content.replace(anchor_sources, new_sources)

    # --- Write the modified file ---
    with open(PROJ_PATH, "w") as f:
        f.write(content)

    print("SUCCESS: Added NudeNetDetector.swift and NudeNetV3.mlpackage to project.pbxproj")
    print(f"  NudeNetDetector.swift  -> FileRef: {NUDENET_SWIFT_FILEREF_ID}, BuildFile: {NUDENET_SWIFT_BUILDFILE_ID}")
    print(f"  NudeNetV3.mlpackage    -> FileRef: {NUDENET_MODEL_FILEREF_ID}, BuildFile: {NUDENET_MODEL_BUILDFILE_ID}")


if __name__ == "__main__":
    main()
