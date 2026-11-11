# copy lc
wget https://github.com/LiveContainer/dylibify/releases/download/1.0/dylibify
chmod +x dylibify
brew install ldid

# move lc to working folder
mv "$archive_path.xcarchive/Products/Applications" Payload

# temporarily move sidestore support framrwork to tmp before zip
mkdir tmp
mv Payload/SealBox.app/Frameworks/SideStoreSupport.framework ./tmp

zip -r "$scheme.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"

mv ./tmp/SideStoreSupport.framework Payload/SealBox.app/Frameworks

# put sidestore related keys into Info.plist and settings bundle
/usr/libexec/PlistBuddy -c 'Add :ALTAppGroups array' ./Payload/SealBox.app/Info.plist
/usr/libexec/PlistBuddy -c 'Add :ALTAppGroups: string group.com.SideStore.SideStore' ./Payload/SealBox.app/Info.plist

/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1 dict" ./Payload/SealBox.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLName string com.mjorb.sealbox.sidestoreurlscheme" ./Payload/SealBox.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes array" ./Payload/SealBox.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes:0 string sidestore" ./Payload/SealBox.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2 dict" ./Payload/SealBox.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLName string com.mjorb.sealbox.sidestorebackupurlscheme" ./Payload/SealBox.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes array" ./Payload/SealBox.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes:0 string sidestore-com.mjorb.sealbox" ./Payload/SealBox.app/Info.plist

/usr/libexec/PlistBuddy -c "Add :INIntentsSupported array" ./Payload/SealBox.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :INIntentsSupported:0 string RefreshAllIntent" ./Payload/SealBox.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :INIntentsSupported:1 string ViewAppIntent" ./Payload/SealBox.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes array" ./Payload/SealBox.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes:0 string RefreshAllIntent" ./Payload/SealBox.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes:1 string ViewAppIntent" ./Payload/SealBox.app/Info.plist

/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Type string PSToggleSwitchSpecifier" ./Payload/SealBox.app/Settings.bundle/Root.plist
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Title string Open SideStore" ./Payload/SealBox.app/Settings.bundle/Root.plist
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Key string LCOpenSideStore" ./Payload/SealBox.app/Settings.bundle/Root.plist
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:DefaultValue bool false" ./Payload/SealBox.app/Settings.bundle/Root.plist

# download SideStore
cd tmp
wget https://github.com/LiveContainer/SideStore/releases/download/nightly/SideStore.ipa
unzip SideStore.ipa
cd ..

# SideStore
mv ./tmp/Payload/SideStore.app ./Payload/SealBox.app/Frameworks/SideStoreApp.framework
./dylibify ./Payload/SealBox.app/Frameworks/SideStoreApp.framework/SideStore ./Payload/SealBox.app/Frameworks/SideStoreApp.framework/SideStore.dylib
rm ./Payload/SealBox.app/Frameworks/SideStoreApp.framework/SideStore
mv ./Payload/SealBox.app/Frameworks/SideStoreApp.framework/SideStore.dylib ./Payload/SealBox.app/Frameworks/SideStoreApp.framework/SideStore
ldid -S"" ./Payload/SealBox.app/Frameworks/SideStoreApp.framework/SideStore
cp ./.github/sidelc/LCAppInfo.plist ./Payload/SealBox.app/Frameworks/SideStoreApp.framework/

# copy intents
cp ./Payload/SealBox.app/Frameworks/SideStoreApp.framework/Intents.intentdefinition ./Payload/SealBox.app/
cp ./Payload/SealBox.app/Frameworks/SideStoreApp.framework/ViewApp.intentdefinition ./Payload/SealBox.app/
cp -r ./Payload/SealBox.app/Frameworks/SideStoreApp.framework/Metadata.appintents ./Payload/SealBox.app/Metadata.appintents
sed -i '' 's/9SideStore20RefreshAllAppsIntentV/16SideStoreSupport20RefreshAllAppsIntentV/g' ./Payload/SealBox.app/Metadata.appintents/extract.actionsdata
sed -i '' 's/9SideStore26RefreshAllAppsWidgetIntentV/16SideStoreSupport26RefreshAllAppsWidgetIntentV/g' ./Payload/SealBox.app/Metadata.appintents/extract.actionsdata

# AltWidgetExtension
mv ./Payload/SealBox.app/Frameworks/SideStoreApp.framework/PlugIns/AltWidgetExtension.appex ./Payload/SealBox.app/PlugIns/LiveWidgetExtension.appex
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mjorb.sealbox.LiveWidget"  ./Payload/SealBox.app/PlugIns/LiveWidgetExtension.appex/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable LiveWidgetExtension"  ./Payload/SealBox.app/PlugIns/LiveWidgetExtension.appex/Info.plist
mv ./Payload/SealBox.app/PlugIns/LiveWidgetExtension.appex/AltWidgetExtension ./Payload/SealBox.app/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension

# Sign
rm -r .zsign_cache
find payloadlc/Payload -type d -name "_CodeSignature" -exec rm -r {} +

ldid -S.github/sidelc/LiveWidgetExtension_adhoc.xml ./Payload/SealBox.app/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension

# package
zip -r "$scheme+SideStore.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"