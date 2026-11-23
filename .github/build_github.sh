# CI code signing (self-signed identity, SealBox flow)
# ------------------------------------------------------
# The archive Xcode produces is only ad-hoc signed (empty CMS slot), so
# the plain IPA cannot be installed as-is. Re-sign the app with a CI-only
# self-signed certificate here, inside this script, because this script
# owns both packaging points: the plain "$scheme.ipa" zip below, and the
# "$scheme+SideStore.ipa" zip at the end (the SideStore surgery in between
# rewrites Info.plist and adds new code, which invalidates the first
# signature, so the app is signed twice: once before each zip).
# MJ re-signs the IPA with his own certificate (3432ZHJUF9) via Seal
# afterwards; this CI signature only has to be a real CMS signature.
#
# TeamIdentifier: a self-signed certificate carries no usable team, and
# codesign leaves the signature's TeamIdentifier "not set" (verified in
# CI run 45050541462: Authority=LiveContainer CI, TeamIdentifier=not set;
# SealBox 0.2.45's shipped binary has no team either). The OU on the
# certificate below therefore does NOT become the TeamIdentifier. The
# LIVE2026CI value lives one level down, in the entitlements:
# application-identifier, team-identifier and keychain-access-groups are
# all expanded with it, consistently, so no AAAAA11111 placeholder
# survives in the entitlements (that is what sign_app asserts below).
# App Groups are the upstream Release values from xcconfigs/Global.xcconfig
# (DEVELOPMENT_TEAM_SUFFIX is empty in Release):
#   group.com.SideStore.SideStore, group.com.rileytestut.AltStore
# Bundle ID stays com.kdt.livecontainer. Each target is signed with its
# own source entitlements file, exactly as Xcode embeds them (verified
# against the unsigned build: appex entitlements carry no
# application-identifier / team-identifier keys, only the main app does).
# $archive_path and $scheme come from the workflow environment.
# Runs under `sh` (POSIX); no `set -e` here on purpose, the pre-existing
# lines below rely on non-fatal failures, so every signing step checks its
# own exit code and aborts explicitly.

CI_CN="LiveContainer CI"
CI_TEAM="LIVE2026CI"
CI_KEYCHAIN="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/lc-ci.keychain-db"
CI_CERT_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/lc-ci-cert"
LC_REPO_ROOT=$(pwd)

setup_ci_signing_identity() {
  mkdir -p "$CI_CERT_DIR" || exit 1
  printf '%s\n' '[req]' 'distinguished_name=dn' 'prompt=no' 'x509_extensions=v3' '[dn]' "CN=$CI_CN" "OU=$CI_TEAM" '[v3]' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' 'extendedKeyUsage=critical,codeSigning' > "$CI_CERT_DIR/ci-cert.cnf"
  openssl req -x509 -newkey rsa:2048 -keyout "$CI_CERT_DIR/ci-key.pem" -out "$CI_CERT_DIR/ci-cert.pem" -days 365 -nodes -config "$CI_CERT_DIR/ci-cert.cnf" || exit 1
  openssl pkcs12 -export -out "$CI_CERT_DIR/ci-cert.p12" -inkey "$CI_CERT_DIR/ci-key.pem" -in "$CI_CERT_DIR/ci-cert.pem" -passout pass:lc-ci -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 || exit 1
  security delete-keychain "$CI_KEYCHAIN" 2>/dev/null || true
  security create-keychain -p "lc-ci" "$CI_KEYCHAIN" || exit 1
  security set-keychain-settings -lut 21600 "$CI_KEYCHAIN"
  security unlock-keychain -p "lc-ci" "$CI_KEYCHAIN" || exit 1
  security import "$CI_CERT_DIR/ci-cert.p12" -k "$CI_KEYCHAIN" -P "lc-ci" -T /usr/bin/codesign || exit 1
  security set-key-partition-list -S apple-tool:,apple: -s -k "lc-ci" "$CI_KEYCHAIN" || exit 1
  security list-keychains -d user -s "$CI_KEYCHAIN" $(security list-keychains -d user | tr -d '"')
  # No `security find-identity -p codesigning` check here on purpose: it
  # does not reliably list a fresh self-signed identity (run 45050128145
  # failed exactly on that check although `security import` had just
  # reported "1 identity imported"). codesign itself is the gate: it
  # fails loudly if the identity is missing, and sign_app asserts the
  # resulting TeamIdentifier and entitlements afterwards.
}

# expand_entitlements <source> <dest> [bundle-id]
# Expand Xcode build variables in an entitlements source file. The
# bundle-id is only needed for the main app (entitlements.xml uses
# $(PRODUCT_BUNDLE_IDENTIFIER)); extension sources do not use it.
expand_entitlements() {
  E_SRC="$1"
  E_DST="$2"
  E_BID="$3"
  if [ -n "$E_BID" ]; then
    sed -e "s/\$(DEVELOPMENT_TEAM)/$CI_TEAM/g" \
        -e "s/\$(APP_GROUP_SIDESTORE)/group.com.SideStore.SideStore/g" \
        -e "s/\$(APP_GROUP_ALTSTORE)/group.com.rileytestut.AltStore/g" \
        -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$E_BID/g" \
        -e "s/\$(AppIdentifierPrefix)/$CI_TEAM./g" \
        -e "s/AAAAA11111/$CI_TEAM/g" \
        "$E_SRC" > "$E_DST" || exit 1
  else
    sed -e "s/\$(DEVELOPMENT_TEAM)/$CI_TEAM/g" \
        -e "s/\$(APP_GROUP_SIDESTORE)/group.com.SideStore.SideStore/g" \
        -e "s/\$(APP_GROUP_ALTSTORE)/group.com.rileytestut.AltStore/g" \
        -e "s/\$(AppIdentifierPrefix)/$CI_TEAM./g" \
        -e "s/AAAAA11111/$CI_TEAM/g" \
        "$E_SRC" > "$E_DST" || exit 1
  fi
  # Fail loudly on any variable left unexpanded, or any placeholder left.
  grep -q '\$(' "$E_DST" && { echo "ERROR: unexpanded variable in $E_DST"; exit 1; }
  grep -q 'AAAAA11111' "$E_DST" && { echo "ERROR: placeholder team left in $E_DST"; exit 1; }
  /usr/bin/plutil -lint "$E_DST" >/dev/null || { echo "ERROR: $E_DST is not a valid plist"; exit 1; }
}

# sign_bundle <path> [entitlements]
sign_bundle() {
  if [ -n "$2" ]; then
    /usr/bin/codesign --force --sign "$CI_CN" --entitlements "$2" --timestamp=none "$1" || exit 1
  else
    /usr/bin/codesign --force --sign "$CI_CN" --timestamp=none "$1" || exit 1
  fi
}

# sign_app <app-path>
# Sign nested code deepest-first, then the app itself. Each app extension
# gets its own source entitlements file; frameworks and loose dylibs are
# signed without entitlements. Call once before each zip that packages
# this Payload.
sign_app() {
  S_APP="$1"
  S_ENT_DIR="$CI_CERT_DIR/entitlements"
  mkdir -p "$S_ENT_DIR" || exit 1
  # App extensions (with their own entitlements; nested frameworks inside
  # an appex, e.g. the SideStore widget's, are signed before the appex).
  for S_APPEX in "$S_APP"/PlugIns/*.appex; do
    [ -d "$S_APPEX" ] || continue
    S_NAME=$(basename "$S_APPEX" .appex)
    case "$S_NAME" in
      LiveProcess) S_SRC="LiveProcess/LiveProcess.entitlements" ;;
      ShareExtension) S_SRC="ShareExtension/ShareExtension.entitlements" ;;
      LaunchAppExtension) S_SRC="LaunchAppExtension/LaunchAppExtension.entitlements" ;;
      LiveWidgetExtension) S_SRC=".github/sidelc/LiveWidgetExtension_adhoc.xml" ;;
      *) S_SRC="" ;;
    esac
    if [ -d "$S_APPEX/Frameworks" ]; then
      for S_FW in "$S_APPEX"/Frameworks/*.framework; do
        [ -d "$S_FW" ] || continue
        sign_bundle "$S_FW"
      done
    fi
    if [ -n "$S_SRC" ]; then
      expand_entitlements "$LC_REPO_ROOT/$S_SRC" "$S_ENT_DIR/$S_NAME.plist"
      sign_bundle "$S_APPEX" "$S_ENT_DIR/$S_NAME.plist"
    else
      echo "warning: no entitlements source for $S_NAME, signing without entitlements"
      sign_bundle "$S_APPEX"
    fi
  done
  # Frameworks, then loose dylibs.
  for S_FW in "$S_APP"/Frameworks/*.framework; do
    [ -d "$S_FW" ] || continue
    sign_bundle "$S_FW"
  done
  for S_DYLIB in "$S_APP"/Frameworks/*.dylib; do
    [ -f "$S_DYLIB" ] || continue
    sign_bundle "$S_DYLIB"
  done
  # Main app last, with the main entitlements.
  S_BID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$S_APP/Info.plist") || exit 1
  expand_entitlements "$LC_REPO_ROOT/entitlements.xml" "$S_ENT_DIR/LiveContainer.plist" "$S_BID"
  sign_bundle "$S_APP" "$S_ENT_DIR/LiveContainer.plist"
  /usr/bin/codesign --verify --deep "$S_APP" || { echo "ERROR: codesign --verify --deep failed for $S_APP"; exit 1; }
  echo "--- signature summary for $S_APP ---"
  for S_TARGET in "$S_APP" "$S_APP"/PlugIns/*.appex; do
    [ -e "$S_TARGET" ] || continue
    echo "--- $(basename "$S_TARGET") ---"
    /usr/bin/codesign -dvvv "$S_TARGET" 2>&1 | grep -E "Identifier=|TeamIdentifier=|Signature size=|Authority=" || true
  done
  # The signature's TeamIdentifier is "not set" for a self-signed CI
  # certificate (codesign does not derive it from the cert OU); accept
  # that, or the CI team if a runner ever reports it. Anything else
  # (e.g. a stale placeholder) fails the run. The entitlements must
  # still carry the CI team as the application-identifier prefix, never
  # the AAAAA11111 placeholder.
  S_TEAM=$(/usr/bin/codesign -dvvv "$S_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  echo "TeamIdentifier=$S_TEAM"
  case "$S_TEAM" in
    "not set"|"$CI_TEAM") ;;
    *) echo "ERROR: unexpected TeamIdentifier $S_TEAM"; exit 1 ;;
  esac
  /usr/bin/codesign -d --entitlements :- "$S_APP" 2>/dev/null | grep -q "$CI_TEAM.$S_BID" || { echo "ERROR: application-identifier prefix is not $CI_TEAM"; exit 1; }
}

setup_ci_signing_identity

# copy lc
wget https://github.com/LiveContainer/dylibify/releases/download/1.0/dylibify
chmod +x dylibify
brew install ldid

# move lc to working folder
mv "$archive_path.xcarchive/Products/Applications" Payload

# temporarily move sidestore support framrwork to tmp before zip
mkdir tmp
mv Payload/LiveContainer.app/Frameworks/SideStoreSupport.framework ./tmp

# Sign the plain IPA payload (real CMS signature; replaces Xcode ad-hoc).
sign_app "Payload/$scheme.app"

zip -r "$scheme.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"

mv ./tmp/SideStoreSupport.framework Payload/LiveContainer.app/Frameworks

# put sidestore related keys into Info.plist and settings bundle
/usr/libexec/PlistBuddy -c 'Add :ALTAppGroups array' ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c 'Add :ALTAppGroups: string group.com.SideStore.SideStore' ./Payload/LiveContainer.app/Info.plist

/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1 dict" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLName string com.kdt.livecontainer.sidestoreurlscheme" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes:0 string sidestore" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2 dict" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLName string com.kdt.livecontainer.sidestorebackupurlscheme" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes:0 string sidestore-com.kdt.livecontainer" ./Payload/LiveContainer.app/Info.plist

/usr/libexec/PlistBuddy -c "Add :INIntentsSupported array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :INIntentsSupported:0 string RefreshAllIntent" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :INIntentsSupported:1 string ViewAppIntent" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes:0 string RefreshAllIntent" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes:1 string ViewAppIntent" ./Payload/LiveContainer.app/Info.plist

/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Type string PSToggleSwitchSpecifier" ./Payload/LiveContainer.app/Settings.bundle/Root.plist
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Title string Open SideStore" ./Payload/LiveContainer.app/Settings.bundle/Root.plist
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Key string LCOpenSideStore" ./Payload/LiveContainer.app/Settings.bundle/Root.plist
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:DefaultValue bool false" ./Payload/LiveContainer.app/Settings.bundle/Root.plist

# download SideStore
cd tmp
wget https://github.com/SideStore/SideStore/releases/download/nightly/SideStore.ipa
unzip SideStore.ipa
cd ..

# SideStore
mv ./tmp/Payload/SideStore.app ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework
./dylibify ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore.dylib
rm ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore
mv ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore.dylib ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore
ldid -S"" ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore
cp ./.github/sidelc/LCAppInfo.plist ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/

# copy intents
cp ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/Intents.intentdefinition ./Payload/LiveContainer.app/
cp ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/ViewApp.intentdefinition ./Payload/LiveContainer.app/
cp -r ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/Metadata.appintents ./Payload/LiveContainer.app/Metadata.appintents
sed -i '' 's/9SideStore20RefreshAllAppsIntentV/16SideStoreSupport20RefreshAllAppsIntentV/g' ./Payload/LiveContainer.app/Metadata.appintents/extract.actionsdata
sed -i '' 's/9SideStore26RefreshAllAppsWidgetIntentV/16SideStoreSupport26RefreshAllAppsWidgetIntentV/g' ./Payload/LiveContainer.app/Metadata.appintents/extract.actionsdata

# AltWidgetExtension
mv ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/PlugIns/AltWidgetExtension.appex ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex
cp -r ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/Frameworks ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.kdt.livecontainer.LiveWidget"  ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable LiveWidgetExtension"  ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/Info.plist
mv ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/AltWidgetExtension ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension

# Sign
rm -r .zsign_cache
find payloadlc/Payload -type d -name "_CodeSignature" -exec rm -r {} +

ldid -S.github/sidelc/LiveWidgetExtension_adhoc.xml ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension

# Re-sign after the SideStore surgery: it rewrote Info.plist and added
# new code (SideStoreApp.framework, LiveWidgetExtension.appex), which
# invalidated the first signature. The ldid lines above are kept as-is;
# codesign --force below replaces their ad-hoc signatures.
sign_app "Payload/$scheme.app"

# package
zip -r "$scheme+SideStore.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"
