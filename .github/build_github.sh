#!/bin/sh
# Sealbox: export the unsigned IPA from the xcarchive produced by CI.
# Runs in .github/workflows/build.yml after `xcodebuild archive`.
# $archive_path and $scheme come from the workflow environment.
# Only standard tools: mv + zip. No downloads, no signing.
set -e

mv "$archive_path.xcarchive/Products/Applications" Payload
zip -r "$scheme.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"
