#!/usr/bin/env python3
"""Generate the 3-target SealBox.xcodeproj/project.pbxproj + shared scheme.

Mechanism: scripted transformation of the proven 0.1.1 base
(commit 087f0661, "Sealbox 0.1.1 (part 1/2)"), which already went through
full CI green with three targets (SealBox app + ZSign dylib + SBGuestHooks
dylib). The base is read from git history, so regenerating is deterministic;
the output is the committed pbxproj, not a second source of truth.

Transformations applied to the base (0.2.0 step 1: container skeleton):
  1. Container modules move Sources/<module> -> Sources/Container/<module>
     (Shared, Store, Importer, Installer, GuestLoader, GuestHooks,
     Certificate). This renames the 7 sync-group paths and the app target's
     HEADER_SEARCH_PATHS entries for GuestLoader/Installer. ZSign and
     SBGuestHooks target configs contain neither path, so they are untouched.
  2. Desktop and Settings sync groups are deleted entirely (the 0.1.7 shell
     owns its own home screen / settings UI) with every reference to them.
  3. IPHONEOS_DEPLOYMENT_TARGET 15.0 -> 16.0 (project + all 3 targets,
     Debug + Release).
  4. App target: MARKETING_VERSION 0.2.8, CURRENT_PROJECT_VERSION 17,
     INFOPLIST_KEY_CFBundleDisplayName "虚拟机" (quoted, as the shell had
     it), iPhone orientations back to portrait-only
     (the 0.1.1 base allowed iPhone landscape; the shell does not).
  5. Scheme: the 0.1.1 scheme verbatim (3 BuildActionEntries); its
     BlueprintIdentifiers must match the target IDs in the new pbxproj.
  6. Container/SealboxApp sync group (0.2.0 step 6 fix): SBAppCoordinator.swift
     and SBLaunchRouter.swift moved Sources/SealboxApp ->
     Sources/Container/SealboxApp in step 1, but no sync group covered that
     directory, so both files silently dropped out of the app target (nothing
     referenced them, CI stayed green until step 6 wired the launch router).
     New sync group ID 5EED00000000000000000053, added to the main group
     children and to the app target's fileSystemSynchronizedGroups.
  7. Seed app (0.2.1): Via-1.9.0.ipa as a plain resource (explicit file
     reference ...54 + build file ...55, in the Resources group and the
     Resources build phase), so SBSeedApps can install it on first launch.

Kept exactly as the base: Security.framework in the app and SBGuestHooks
Frameworks phases; Embed Frameworks (ZSign.dylib, SBGuestHooks.dylib,
OpenSSL.xcframework); target dependencies; DYLIB_INSTALL_NAME_BASE =
"@rpath" (quoted); xcconfigs via baseConfigurationReferenceAnchor +
RelativePath (a bare baseConfigurationReference is silently ignored and
must never appear); litehook sync group covering litehook/src only;
OpenSSL.xcframework at OpenSSL/Frameworks/OpenSSL.xcframework.

Self-checks (fail loudly, write nothing on failure):
  - every referenced 24-hex object ID exists as a definition;
  - no bare baseConfigurationReference;
  - no Desktop/Settings residue;
  - the xcconfigs anchor exists and every sync-group path exists on disk
    or is a known submodule path (litehook/src, fetched by CI);
  - scheme BlueprintIdentifiers exist in the pbxproj;
  - version / deployment-target / display-name / orientation markers.

Run: python3 gen-pbxproj.py  (writes project.pbxproj + SealBox.xcscheme)
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
BASE_COMMIT = "087f0661"
PBXPROJ = os.path.join(ROOT, "SealBox.xcodeproj", "project.pbxproj")
SCHEME = os.path.join(
    ROOT, "SealBox.xcodeproj", "xcshareddata", "xcschemes", "SealBox.xcscheme")

# 24-hex object IDs of the sync groups that move under Sources/Container/.
MOVED_MODULES = ("Shared", "Store", "Importer", "Installer",
                 "GuestLoader", "GuestHooks", "Certificate")
# Sync-group object IDs removed with the Desktop/Settings groups.
REMOVED_GROUPS = {
    "5EED0000000000000000001D": "Desktop",
    "5EED0000000000000000001E": "Settings",
}
# Sync-group object ID for Sources/Container/SealboxApp (step 6 fix).
# ...53 is above every ID used in the 0.1.1 base, so it cannot collide.
CONTAINER_SEALBOXAPP_GROUP_ID = "5EED00000000000000000053"
# Seed-app resource (0.2.1, step 7): Via IPA bundled as a plain resource.
# ...54 (file reference) and ...55 (build file) are above ...53.
VIA_IPA_FILEREF_ID = "5EED00000000000000000054"
VIA_IPA_BUILDFILE_ID = "5EED00000000000000000055"
VIA_IPA_PATH = "Resources/SeedApps/Via-1.9.0.ipa"
# App target XCBuildConfiguration object IDs (Debug, Release).
APP_CONFIGS = ("5EED00000000000000000040", "5EED00000000000000000041")
# Paths provided by CI-cloned submodules, not present in a plain checkout.
SUBMODULE_PATHS = {"litehook/src"}
# The xcconfigs sync group, used as baseConfigurationReferenceAnchor.
XCCONFIGS_ANCHOR = "5EED00000000000000000021"


def git_show(path):
    out = subprocess.run(
        ["git", "show", "%s:%s" % (BASE_COMMIT, path)],
        cwd=ROOT, capture_output=True, text=True, check=False)
    if out.returncode != 0:
        sys.exit("gen-pbxproj: cannot read %s from %s: %s"
                 % (path, BASE_COMMIT, out.stderr.strip()))
    return out.stdout


def replace_once(text, old, new, where):
    n = text.count(old)
    if n != 1:
        sys.exit("gen-pbxproj: expected 1 occurrence of %r in %s, found %d"
                 % (old, where, n))
    return text.replace(old, new)


def transform_pbxproj(base):
    text = base

    # 1. Container module paths (sync groups + app HEADER_SEARCH_PATHS).
    for mod in MOVED_MODULES:
        old = "Sources/%s" % mod
        new = "Sources/Container/%s" % mod
        n = text.count(old)
        if n < 1:
            sys.exit("gen-pbxproj: %r not found in base pbxproj" % old)
        text = text.replace(old, new)

    # 2. Delete the Desktop / Settings sync-group objects wholesale.
    for gid, name in REMOVED_GROUPS.items():
        pat = re.compile(
            r"\t\t%s /\* %s \*/ = \{.*?\n\t\t\};\n" % (gid, name),
            re.DOTALL)
        text, n = pat.subn("", text)
        if n != 1:
            sys.exit("gen-pbxproj: expected 1 %s sync-group block, removed %d"
                     % (name, n))
        # Every reference to the group ("<id> /* <name> */, ") must go.
        ref = "%s /* %s */, " % (gid, name)
        if ref not in text:
            sys.exit("gen-pbxproj: no reference left to remove for %s" % name)
        text = text.replace(ref, "")

    # 3. Deployment target 15.0 -> 16.0 (project + 3 targets x Debug/Release).
    n = text.count("IPHONEOS_DEPLOYMENT_TARGET = 15.0;")
    if n != 8:
        sys.exit("gen-pbxproj: expected 8 deployment-target lines, found %d"
                 % n)
    text = text.replace("IPHONEOS_DEPLOYMENT_TARGET = 15.0;",
                        "IPHONEOS_DEPLOYMENT_TARGET = 16.0;")

    # 4. App target build settings (Debug + Release blocks only).
    for cfg in APP_CONFIGS:
        start = text.find("\t\t%s /* " % cfg)
        if start < 0:
            sys.exit("gen-pbxproj: app config %s not found" % cfg)
        end = text.find("\n\t\t};", start)
        if end < 0:
            sys.exit("gen-pbxproj: app config %s has no end" % cfg)
        end += len("\n\t\t};")
        block = text[start:end]
        block = replace_once(block, "MARKETING_VERSION = 0.1.1;",
                             "MARKETING_VERSION = 0.2.8;", cfg)
        block = replace_once(block, "CURRENT_PROJECT_VERSION = 2;",
                             "CURRENT_PROJECT_VERSION = 17;", cfg)
        block = replace_once(block,
                             "INFOPLIST_KEY_CFBundleDisplayName = Sealbox;",
                             "INFOPLIST_KEY_CFBundleDisplayName = \"虚拟机\";",
                             cfg)
        block = replace_once(
            block,
            "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "
            "\"UIInterfaceOrientationPortrait "
            "UIInterfaceOrientationLandscapeLeft "
            "UIInterfaceOrientationLandscapeRight\";",
            "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "
            "UIInterfaceOrientationPortrait;",
            cfg)
        text = text[:start] + block + text[end:]

    # 5. Container/SealboxApp sync group (step 6 fix): SBAppCoordinator.swift
    #    and SBLaunchRouter.swift moved Sources/SealboxApp ->
    #    Sources/Container/SealboxApp in step 1, but no sync group covered
    #    that directory, so both files silently dropped out of the app
    #    target (nothing referenced them, CI stayed green until step 6
    #    wired the launch router). New group ID ...53, unused in the base.
    new_group = (
        "\t\t%s /* SealboxApp */ = {\n"
        "\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n"
        "\t\t\texplicitFileTypes = {};\n"
        "\t\t\texplicitFolders = ();\n"
        "\t\t\tpath = \"Sources/Container/SealboxApp\";\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n" % CONTAINER_SEALBOXAPP_GROUP_ID
    )
    cert_group_end = (
        "\t\t\tpath = \"Sources/Container/Certificate\";\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n"
    )
    text = replace_once(text, cert_group_end, cert_group_end + new_group,
                        "Certificate sync-group block")
    text = replace_once(
        text,
        "5EED0000000000000000001C /* Certificate */, "
        "5EED0000000000000000001F /* GuestHooks */, ",
        "5EED0000000000000000001C /* Certificate */, "
        "%s /* SealboxApp */, "
        "5EED0000000000000000001F /* GuestHooks */, "
        % CONTAINER_SEALBOXAPP_GROUP_ID,
        "main group children")
    text = replace_once(
        text,
        "5EED0000000000000000001C /* Certificate */, "
        "5EED00000000000000000022 /* litehook */, ",
        "5EED0000000000000000001C /* Certificate */, "
        "%s /* SealboxApp */, "
        "5EED00000000000000000022 /* litehook */, "
        % CONTAINER_SEALBOXAPP_GROUP_ID,
        "app target fileSystemSynchronizedGroups")

    # 7. Seed app (0.2.1): bundle Via-1.9.0.ipa as a plain resource so the
    # app can install it on first launch (SBSeedApps). Explicit file
    # reference + build file, NOT a sync group: Resources is a plain
    # PBXGroup in the base, and a synced group would drag the whole
    # directory (including the .xcassets) into the target a second way.
    # The file lands at the bundle root as Via-1.9.0.ipa (group paths are
    # flattened for resources); SBSeedApps also tries SeedApps/ as fallback.
    via_fileref = (
        "\t\t%s /* Via-1.9.0.ipa */ = {\n"
        "\t\t\tisa = PBXFileReference;\n"
        "\t\t\tlastKnownFileType = file;\n"
        "\t\t\tname = \"Via-1.9.0.ipa\";\n"
        "\t\t\tpath = \"SeedApps/Via-1.9.0.ipa\";\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n" % VIA_IPA_FILEREF_ID
    )
    assets_fileref_end = (
        "\t\t5EED00000000000000000007 /* Assets.xcassets */ = {\n"
        "\t\t\tisa = PBXFileReference;\n"
        "\t\t\tlastKnownFileType = \"folder.assetcatalog\";\n"
        "\t\t\tname = \"Assets.xcassets\";\n"
        "\t\t\tpath = \"Assets.xcassets\";\n"
        "\t\t\tsourceTree = \"<group>\";\n"
        "\t\t};\n"
    )
    text = replace_once(text, assets_fileref_end,
                        assets_fileref_end + via_fileref,
                        "Assets file reference block")
    via_buildfile = (
        "\t\t%s /* Via-1.9.0.ipa */ = {\n"
        "\t\t\tisa = PBXBuildFile;\n"
        "\t\t\tfileRef = %s /* Via-1.9.0.ipa */;\n"
        "\t\t};\n" % (VIA_IPA_BUILDFILE_ID, VIA_IPA_FILEREF_ID)
    )
    assets_buildfile = (
        "\t\t5EED0000000000000000002F /* Assets.xcassets */ = {\n"
        "\t\t\tisa = PBXBuildFile;\n"
        "\t\t\tfileRef = 5EED00000000000000000007 /* Assets.xcassets */;\n"
        "\t\t};\n"
    )
    text = replace_once(text, assets_buildfile,
                        assets_buildfile + via_buildfile,
                        "Assets build file block")
    text = replace_once(
        text,
        "children = (5EED00000000000000000007 /* Assets.xcassets */, );",
        "children = (5EED00000000000000000007 /* Assets.xcassets */, "
        "%s /* Via-1.9.0.ipa */, );" % VIA_IPA_FILEREF_ID,
        "Resources group children")
    text = replace_once(
        text,
        "files = (5EED0000000000000000002F /* Assets.xcassets */, );",
        "files = (5EED0000000000000000002F /* Assets.xcassets */, "
        "%s /* Via-1.9.0.ipa */, );" % VIA_IPA_BUILDFILE_ID,
        "Resources build phase files")

    return text


def self_check(pbxproj, scheme):
    errors = []

    # Every referenced 24-hex ID exists as an object definition.
    defined = set(re.findall(r"\n\t\t([0-9A-F]{24}) /\*", pbxproj))
    referenced = set(re.findall(r"\b([0-9A-F]{24})\b", pbxproj))
    missing = sorted(referenced - defined)
    if missing:
        errors.append("referenced IDs with no definition: %s" % missing)

    # No bare baseConfigurationReference (must be Anchor + RelativePath).
    if re.search(r"baseConfigurationReference\s*=", pbxproj):
        errors.append("bare baseConfigurationReference present")
    if pbxproj.count("baseConfigurationReferenceAnchor") != 8:
        errors.append("expected 8 baseConfigurationReferenceAnchor lines, "
                      "found %d"
                      % pbxproj.count("baseConfigurationReferenceAnchor"))
    if XCCONFIGS_ANCHOR not in defined:
        errors.append("xcconfigs anchor %s missing" % XCCONFIGS_ANCHOR)

    # No Desktop / Settings residue (word-boundary: "buildSettings" is fine).
    for word in ("Desktop", "Settings"):
        if re.search(r"\b%s\b" % word, pbxproj):
            errors.append("residue: %r still in pbxproj" % word)

    # Sync-group paths exist on disk or are known submodule paths.
    for m in re.finditer(
            r"isa = PBXFileSystemSynchronizedRootGroup;\n"
            r"(?:.*\n)*?\t\t\tpath = \"([^\"]+)\";", pbxproj):
        p = m.group(1)
        if p in SUBMODULE_PATHS:
            continue
        if not os.path.exists(os.path.join(ROOT, p)):
            errors.append("sync-group path missing on disk: %s" % p)

    # Quoted DYLIB_INSTALL_NAME_BASE kept (4x: ZSign + Hooks, Dbg + Rel).
    if pbxproj.count('DYLIB_INSTALL_NAME_BASE = "@rpath";') != 4:
        errors.append("DYLIB_INSTALL_NAME_BASE quoted form not x4")

    # Seed Via IPA (0.2.1): file on disk, file reference + build file in
    # the pbxproj, and membership in the Resources build phase.
    if not os.path.exists(os.path.join(ROOT, VIA_IPA_PATH)):
        errors.append("seed Via IPA missing on disk: %s" % VIA_IPA_PATH)
    if VIA_IPA_FILEREF_ID not in defined:
        errors.append("Via IPA file reference %s missing" % VIA_IPA_FILEREF_ID)
    if VIA_IPA_BUILDFILE_ID not in defined:
        errors.append("Via IPA build file %s missing" % VIA_IPA_BUILDFILE_ID)
    if pbxproj.count("%s /* Via-1.9.0.ipa */" % VIA_IPA_BUILDFILE_ID) != 2:
        errors.append("Via IPA not in Resources build phase files")

    # Version / target markers.
    if pbxproj.count("MARKETING_VERSION = 0.2.8;") != 2:
        errors.append("MARKETING_VERSION 0.2.8 not in both app configs")
    if pbxproj.count("CURRENT_PROJECT_VERSION = 17;") != 2:
        errors.append("CURRENT_PROJECT_VERSION 17 not in both app configs")
    if pbxproj.count("IPHONEOS_DEPLOYMENT_TARGET = 16.0;") != 8:
        errors.append("deployment target 16.0 not x8")
    if "IPHONEOS_DEPLOYMENT_TARGET = 15.0;" in pbxproj:
        errors.append("stale deployment target 15.0 remains")
    if pbxproj.count('INFOPLIST_KEY_CFBundleDisplayName = "虚拟机";') != 2:
        errors.append("display name not 虚拟机 in both app configs")

    # Scheme BlueprintIdentifiers exist in the pbxproj.
    for bid in re.findall(r'BlueprintIdentifier = "([0-9A-F]{24})"', scheme):
        if bid not in defined:
            errors.append("scheme BlueprintIdentifier %s not in pbxproj"
                          % bid)
    if scheme.count("<BuildActionEntry") != 3:
        errors.append("scheme must have 3 BuildActionEntries")

    # ZSign / SBGuestHooks target configs must not contain Container paths.
    for cfg in ("5EED00000000000000000042", "5EED00000000000000000043",
                "5EED00000000000000000044", "5EED00000000000000000045"):
        start = pbxproj.find("\t\t%s /* " % cfg)
        end = pbxproj.find("\n\t\t};", start)
        if "Sources/Container" in pbxproj[start:end]:
            errors.append("Container path leaked into %s config" % cfg)

    if errors:
        for e in errors:
            print("gen-pbxproj SELF-CHECK FAILED: %s" % e, file=sys.stderr)
        sys.exit(1)


def main():
    base_pbx = git_show("SealBox.xcodeproj/project.pbxproj")
    base_scheme = git_show(
        "SealBox.xcodeproj/xcshareddata/xcschemes/SealBox.xcscheme")
    pbxproj = transform_pbxproj(base_pbx)
    self_check(pbxproj, base_scheme)
    with open(PBXPROJ, "w", encoding="utf-8") as fh:
        fh.write(pbxproj)
    with open(SCHEME, "w", encoding="utf-8") as fh:
        fh.write(base_scheme)
    print("wrote %s" % PBXPROJ)
    print("wrote %s" % SCHEME)
    print("self-check passed")


if __name__ == "__main__":
    main()
