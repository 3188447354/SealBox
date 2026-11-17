#!/bin/sh
# Sealbox: export the ad-hoc signed IPA from the xcarchive produced by CI.
# Runs in .github/workflows/build.yml after `xcodebuild archive`.
# $archive_path and $scheme come from the workflow environment.
# The app was ad-hoc signed at archive time (CODE_SIGN_IDENTITY="-") with
# entitlements.xml embedded, so Seal can read the entitlements from the
# binary and allocate the App Group when re-signing. Only standard tools:
# mv + zip. No downloads, no further signing.
set -e

mv "$archive_path.xcarchive/Products/Applications" Payload
zip -r "$scheme.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"
