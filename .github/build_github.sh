# SealBox 0.0.3 rebuild: package the main app IPA only.
# The SideStore variant (+SideStore.ipa) is gone with SideStoreSupport:
# no SideStoreSupport.framework move, no PlistBuddy SideStore/intent
# keys, no SideStore nightly download, no dylibify/ldid of SideStoreApp,
# no intents copy, no AltWidgetExtension -> LiveWidgetExtension rename.
# dylibify + ldid are still fetched (kept for future packaging steps);
# the archive itself is built unsigned by build.yml.
wget https://github.com/LiveContainer/dylibify/releases/download/1.0/dylibify
chmod +x dylibify
brew install ldid

# move lc to working folder
mv "$archive_path.xcarchive/Products/Applications" Payload

zip -r "$scheme.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"
