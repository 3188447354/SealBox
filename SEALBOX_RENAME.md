# SealBox 改名报告

分支：`desktop-grid-v1`（基线：上游 `9108ae62`，桌面 v1 代码提交 `15b34d2`）
本次提交：`desktop-grid-v1` 分支 head（改名 + 壁纸/主题 + 真实删除 + 本报告；hash 见 `git log`，报告文件无法自带本提交的 hash）
日期：2026-11-08

本次改名 + 桌面壁纸/主题 + 桌面真实删除，三件事同一提交。
**未编译**：本机 Linux 无 Xcode，全部只做了静态检查，须 Mac / GitHub Actions（Xcode 26.2）构建验证（见“验证”与“上传准备”）。

---

## 1. 改名：旧值 → 新值

| 项目 | 旧值 | 新值 |
|---|---|---|
| App 显示名 | LiveContainer | SealBox |
| 主 Bundle ID | `com.kdt.livecontainer` | `com.mjorb.sealbox` |
| LiveProcess | `com.kdt.livecontainer.LiveProcess` | `com.mjorb.sealbox.LiveProcess` |
| ShareExtension | `com.kdt.livecontainer.ShareExtension` | `com.mjorb.sealbox.ShareExtension` |
| LaunchAppExtension | `com.kdt.livecontainer.LaunchAppExtension` | `com.mjorb.sealbox.LaunchAppExtension` |
| URL Scheme | `livecontainer` / `livecontainer2` / `livecontainer3` | `sealbox` / `sealbox2` / `sealbox3` |
| 钥匙串组前缀 | `com.kdt.livecontainer.shared` | `com.mjorb.sealbox.shared` |
| App Group | `group.com.SideStore.SideStore` / `group.com.rileytestut.AltStore` | `group.com.mjorb.sealbox` |
| Team ID | `AAAAA11111`（占位） | 保持占位，未编真的 Team ID |
| SwiftUI 框架 Bundle ID | `com.kdtLiveContainerSwiftUI` | `com.mjorb.sealbox.LiveContainerSwiftUI` |
| 多开克隆 Bundle ID（`LCUtils.m:320`，装 SealBox2/3 时给克隆体写 ID） | `com.kdt.<名字>` | `com.mjorb.sealbox.<名字>` |

### 改了哪些地方

- `xcconfigs/Global.xcconfig`：`LIVECONTAINER_BUNDLE_IDENTIFIER = com.mjorb.sealbox$(DEVELOPMENT_TEAM_SUFFIX)`；新增 `APP_GROUP_SEALBOX = group.com.mjorb.sealbox$(DEVELOPMENT_TEAM_SUFFIX)`，旧的 `APP_GROUP_SIDESTORE` / `APP_GROUP_ALTSTORE` 两个变量已删。各 target 的 xcconfig（`LiveContainer` / `LiveProcess` / `ShareExtension` / `LaunchAppExtension`）仍引用 `$(LIVECONTAINER_BUNDLE_IDENTIFIER)`，不用逐个改。
- `LiveContainer/Info.plist`：`CFBundleDisplayName` / `CFBundleName` → SealBox；三个 URL Scheme → sealbox / sealbox2 / sealbox3；`CFBundleURLName` → 新主 ID；`LSApplicationQueriesSchemes` 同步。
- `LiveProcess/Info.plist`：`CFBundleURLName` → 新主 ID；`liveprocess` scheme 保留（它是 LiveProcess 自己的，不在改名表里）。
- 四份 entitlements（`entitlements.xml`、`LiveProcess/LiveProcess.entitlements`、`ShareExtension/ShareExtension.entitlements`、`LaunchAppExtension/LaunchAppExtension.entitlements`）：128 个钥匙串组前缀全改，App Group 改成单个 `$(APP_GROUP_SEALBOX)`。`entitlements.catalyst.xml` 同步（`AAAAA11111.com.mjorb.sealbox`）。
- 代码里的 Scheme 判断：`Shared.swift` 的 `appUrlScheme()`、`LCAppModel.swift` 的 `livecontainer-launch`、`LaunchAppExtension.swift` 的 scheme 判断、`LCSharedUtils.m` / `LCUtils.m` / `SideStoreHooks.m` 的组名与 Bundle ID，全部按表换。
- 用户可见文案：设置页、关于页、报错提示、JIT 提示（`LCUtilsExtensions.swift` 8 处 “in LiveContainer / another LiveContainer” → SealBox）、Web Clip 描述（`LCAppInfo.m` 2 处）、“LiveProcess extension not found. Please reinstall SealBox and select Keep Extensions”（`LCUtils.m:60`）、数据管理页 “SealBox Bundle”。`Localizable.xcstrings` 与 39 个语种的 `InfoPlist.strings` 里的显示名全部改成 SealBox；机械替换产生的 `SealBoxs` 已统一改成 `SealBoxes`。
- App 图标（占位，见 §5）。

### 先别动的（有意保留）

- 内部 target 名、文件夹名、文件名里的 LiveContainer 不改；`CFBundleExecutable` 仍是 `LiveContainer`（二进制名）。
- App Group 里存数据的 `LiveContainer` 文件夹名不改（`LCBootstrap.m`、`LCSharedUtils.m`、`Shared.swift`、`ShareExtensionViewModel.swift`、`TweakLoader/UIKit+GuestHooks.m` 等路径仍是 `…/LiveContainer/…`）。
- 变量名、类名不改：`hideLiveContainer`、`LCAppModel`、`isLiveContainerURL`、`PrimaryLiveContainerTeamId`、`generateLiveContainerWrappedIcon` 等，读写两端一致，改了反而断。
- `LCSettingsView.swift:289` 的 `Button("LiveContainer/LiveContainer")` 不改：它是上游 GitHub 仓库链接的按钮文案，指向的还是上游仓库。
- `Dyld.m:708` 的 “Create an issue on LiveContainer GitHub” 不改：指向的上游仓库。
- `LCAppInfo.m:315` 的备份文件名后缀 `_LiveContainerPatchBackUp` 不改：改了会认不出旧备份。
- `SideStoreSupport` 没动、内置 SideStore 没删、`JITEnablerType` 没改、没加 Seal 的 Scheme（MJ 定：先不改，后面再根据实际来改）。
- LICENSE 保持 AGPL-3.0，未动。
- 桌面网格 v1 的拖动、分页、Dock 逻辑没动，只改其中出现的显示名和 Scheme。

### 已知的改名副作用（须真机验证）

- `LCUtils.store()` 的回退判定看 App Group 名里含不含 “SideStore”/“AltStore”，新组都不含，`store()` 会落到 ADP 分支，`getStoreName()` 显示 “ADP”，设置页里“从商店刷新/导入证书”的文案会变。
- `SideStoreHooks.m` 的 `hook_baseAltStoreAppGroupID` 已指向新组，内置 SideStore 的组查找行为待真机验证。

---

## 2. 验证

本机 Linux，无 Xcode，**未编译**。以下全部是静态验证，2026-11-08 跑过：

1. 全仓 grep（0 条为通过）：
   - `grep -rn "com.kdt.livecontainer" --include="*.plist" --include="*.xcconfig" --include="*.entitlements" .` → **0 条**
   - `grep -rn "livecontainer://" --include="*.swift" --include="*.m" .` → **0 条**
   - `grep -rn "com.kdt\|kdtLiveContainerSwiftUI" .`（除 `.github/` 与两份历史报告 `INVENTORY.md` / `DESKTOP_GRID_V1.md`）→ **0 条**
   - 注释里的 GitHub 链接（`github.com/LiveContainer/...`）除外，逐条说明：它们指向上游仓库，不是本 App 的标识，不改。
2. 钥匙串组程序比对（plistlib 读两份 entitlements，不是肉眼）：主 App **128 个**，LiveProcess **128 个**，**完全一致**，前缀全部是 `com.mjorb.sealbox.shared`（`.shared` ～ `.shared.127`）。
3. Bundle ID：主 App `com.mjorb.sealbox`；LiveProcess `com.mjorb.sealbox.LiveProcess`；ShareExtension `com.mjorb.sealbox.ShareExtension`；LaunchAppExtension `com.mjorb.sealbox.LaunchAppExtension`；框架 `com.mjorb.sealbox.SideStoreSupport` / `com.mjorb.sealbox.LiveContainerShared` / `com.mjorb.sealbox.LiveContainerSwiftUI`。各不相同，都是新主 ID + 后缀。
4. 静态检查：本次改动的 19 个 Swift 文件（含新文件 `LCDesktopWallpaper.swift`）括号/圆括号/方括号全部配平；`LCDesktopTheme` 的四个计算属性（`displayName` / `colorScheme` / `nameColor` / `wallpaperDim`）三个分支全有返回值；新增的 `import` 只有 `LCDesktopWallpaper.swift` 里的 PhotosUI（PHPicker）与 SwiftUI，未动其他文件的 import。
5. 残留的 “LiveContainer” 字样只剩四类，都是有意保留：① 文件头注释 `// LiveContainer`；② 内部标识（文件夹名、类名、变量名、框架名、`LiveContainer/` 路径、App Group 数据文件夹）；③ 上游 GitHub 链接与 `LiveContainer/LiveContainer` 仓库按钮；④ 多开管理页的内部变量名 `knownLiveContainers`。用户在界面上能看到的已全部改成 SealBox。

---

## 3. 桌面壁纸与主题（MJ 追加）

### 入口：右上角只放一个「···」

- 桌面**常态**右上角只放一个「···」按钮（SF Symbol `ellipsis`，三个点），不要直接放壁纸图标。
- 点「···」弹出**系统 Menu**（原生浮层）：点外面就收起，不挡住桌面，不用另外做遮罩。
- 菜单里三个项：
  1. **壁纸**（`photo` 图标）→ 打开系统照片选择器 → 选完进编辑页 → 确认后应用。
  2. **主题色** → 子菜单，三个选项：跟随系统 / 深色 / 浅色，点一下立即切换。
  3. **恢复默认壁纸**（红色）→ 弹确认框，确认后删掉存的壁纸，回到默认背景。
- **编辑模式下右上角还是 ✓**，「···」只在常态显示，两者不冲突。主题切换入口在菜单里，**不在设置页**（之前“设置页加外观行”的方案已作废）。

### 选图方式

- 用系统照片选择器 **PHPickerViewController**（`LCPhotoPicker`，包 UIKit 的选择器），不是文件选择器。原因：SwiftUI 的 PhotosPicker 要求 iOS 16，App 部署目标是 iOS 15；PHPicker 从 iOS 14 就能用，底层和 PhotosPicker 是同一个选择器，**只能选一张图片**（`selectionLimit = 1`，`filter = .images`），不需要完整相册权限。
- 选完不直接换，先打开编辑页（`LCWallpaperEditView`，全屏），**确认后才应用，取消不改原壁纸**。

### 编辑壁纸：能调四项

- **裁剪/缩放定位**：拖动平移 + 缩放滑条（1×～3×），居中裁剪铺满；边缘有钳制，图片始终盖满预览，不会露出底色。
- **亮度**：滑条 -0.5 ～ +0.5。
- **模糊**：滑条 0 ～ 20。
- 不要滤镜库、不要贴纸。

### 存哪、怎么持久化

- 壁纸存在 App Group 容器下 `SealBoxWallpaper/wallpaper.jpg`，编辑参数存在同目录 `SealBoxWallpaper/wallpaper.json`（`LCDesktopWallpaperSettings`：brightness / blur / scale / offsetX / offsetY）。App Group 不可用时回退到 App 的 Documents 下同名目录。
- 存的时候下缩到最长边 2048px、JPEG 0.85，不存原图。重启 App 后 `LCDesktopWallpaperStore.load()` 读回，壁纸还在。
- 主题存在 App Group UserDefaults 的 `LCDesktopTheme`（`@AppStorage`），值是 `system` / `dark` / `light`，重启后还在。

### 主题三个选项分别怎么显示

- **跟随系统**：名字颜色用系统 `.primary`，Dock 磨砂跟系统走，背景不加遮罩。
- **深色**：图标名字变白，Dock 磨砂变深（`.preferredColorScheme(.dark)` 覆盖，`.ultraThinMaterial` 自动变深），壁纸上盖一层黑 0.35 的遮罩，背景变暗。
- **浅色**：图标名字变深（黑），Dock 变浅，壁纸上盖一层白 0.20 的遮罩，背景变亮。
- Dock 不用单独改：它用的 `.ultraThinMaterial` 会随 `.preferredColorScheme` 自动变深/变浅。

### 壁纸和主题是两套东西

- 壁纸是背景图，主题是深浅配色，分开存（`SealBoxWallpaper/` vs `LCDesktopTheme`）。换壁纸不重置主题，换主题不丢壁纸。
- **深色壁纸 + 浅色主题也看得清**：图标名字除了按主题变色，还永远带一层阴影（黑 0.55、半径 2、向下 1pt）兜底；浅色主题时壁纸上的白色遮罩只提亮背景、不动文字；底部计数文字也加了同样的阴影。

### 没改的东西

- 桌面网格、分页、Dock、拖动的逻辑没动；SideStore / JIT 没动。

---

## 4. 桌面真实删除（MJ 追加，推翻 v1 报告里的缺口）

v1 报告里写的是“点 − 只从列表拿掉、不删文件”，**已作废**。现在点 − 就是真实删除。

### 接的是哪个 uninstall()

- 接的是旧代码 `LCAppBannerViewController.uninstall()`（长按菜单里的“卸载”一直走的就是它），不是新写的一套。
- 做法：把 `uninstall()` 里删文件的核心抽成共用函数 `LCAppModel.uninstallFiles(for:removeDataFolders:)`（`LCAppModel.swift`），横幅的 `uninstall()` 与网格的 `deleteDesktopApp` 都调它，删的路径完全一致。横幅原来的两次确认与报错显示原样保留，只把删文件那几行换成调共用函数。
- 唯一行为差别（失败路径上）：原来删数据文件夹中途失败时，模型已经先从列表里拿掉了；现在是文件删完才拿模型，失败时 App 仍留在桌面、弹报错，用户可以重试。删成功的路径完全一样。

### 删了哪些路径（逐个接上）

以客 App `Foo.app`、数据容器 `dataUUID` 为例：

1. App bundle 文件夹：`Documents/Applications/Foo.app`（`appInfo.bundlePath()`）——一定删。
2. 数据容器文件夹：`Documents/Data/Application/<dataUUID>/`，这个 App 的**每一个**容器都删（`appInfo.containers` 逐个删）。
3. 钥匙串：每个容器的 `LCUtils.removeAppKeychain(dataUUID:)`（按 `alis == dataUUID` 删通用密码、互联网密码、证书、密钥、身份五类）。
4. 注册表：`DataManager.shared.model.appDataFolderNames` 里对应的 dataUUID 逐条清除。

### 共享 / 多开容器怎么处理

- **共享 App（`uiIsShared`）不删**：它的 bundle 和数据是别的实例共用的，删了会连累别人。横幅菜单本来就不给共享 App 显示“卸载”；网格照同一条规矩：`LCDesktopIcon.isDeletable` 对共享 App 返回 false，**没有 − 角标**；`deleteDesktopApp` 里还有第二道防线，共享 App 直接拒绝。
- **多开实例**：一个 App 的多个容器各有自己的 dataUUID 文件夹，删这个 App 时只删它自己的容器列表里的文件夹，不会碰别的 App 的数据。删 App 就是删它全部实例的数据——和横幅卸载的原有逻辑一致。
- **系统图标**（源 / 设置 / 插件）没有 −，删不到它们。
- **Dock 里的 − 还是“移出 Dock、回网格”**，不是删除 App，不要混：`removeIconFromDock` 只把图标从 Dock 拿掉、插回网格末尾，文件一根没动。

### 删除流程与删完桌面怎么更新

1. 编辑模式点图标左上角 − → 弹确认框，文案用已有的 `lc.appBanner.confirmUninstallTitle` / `lc.appBanner.confirmUninstallMsg <名字>`（一次确认就覆盖 bundle + 数据 + 钥匙串，不像横幅那样再问一次“要不要删数据”——网格的 − 就是全删）。
2. 点“卸载”后调 `deleteDesktopApp`：先删文件，失败就弹 `lc.common.error` 报错、桌面不动；成功才 `removeApp`（从 `sharedModel.apps` / `hiddenApps` 拿掉模型）+ 从桌面顺序里拿掉 + 从 Dock 里拿掉 + `refreshDock()`。
3. 网格、Dock、页点都由桌面顺序驱动，顺序一变自动刷新；删的是最后一页最后一个时，页数少一个，当前页由已有的 `.onChange(of: desktopPageCount)` 自动钳制到最后一页，不会停在不存在的页上。

---

## 5. App 图标：占位方案

没有现成的 SealBox 图标文件，**先用纯色占位图标**，不要用旧的 LiveContainer 图标。正式图标待 MJ 定。

- 主图标 `AppIcon.appiconset/` 三张 1024×1024：`AppIcon1024.png` 纯蓝 `#2E6BFF`；`AppIconDark1024.png` 深蓝 `#1E40AF`（RGBA）；`AppIconDark1024 1.png` 纯蓝（着色版）。
- 灰色套装 `AppIconGrey.appiconset/` 三张 1024×1024（多开 LC2/LC3 用的灰色图标）：`AppIconGrey1024.png` 纯灰 `#8E8E93`；`AppIconGreyDark1024.png` 深灰 `#636366`（RGBA）；`AppIconGreyDark1024 1.png` 纯灰。
- 散装两张：`Resources/AppIconGrey60x60@2x.png`（120×120，纯灰）、`Resources/AppIconGrey76x76@2x~ipad.png`（152×152，纯灰）。
- `Resources/DefaultIcon.png`（180×180，客 App 默认图标）不动。
- 文件名、尺寸、asset catalog 引用都没变，只换了像素内容，编译期不会因为缺图标报错；但桌面上看到的就是一块纯色，**必须换正式图标才能发版**。

---

## 6. 上传准备

- **要推的分支**：`desktop-grid-v1`（不要推 main，不要新建远程）。
- **要推的 commit**：`desktop-grid-v1` 的 head 提交（改名 + 壁纸/主题 + 真实删除 + 本报告，见 `git log`）。
- **仓库建议名**：SealBox。
- **GitHub Actions 构建用的 workflow 在不在树里**：在，`.github/workflows/build.yml`（上游原样，未改）。
- **它用什么 Xcode、什么命令**（现场核对过文件内容）：
  - Runner：`macos-latest`；Xcode：`26.2`（`maxim-lobanov/setup-xcode@v1`）。
  - Checkout 带 `submodules: recursive`（`litehook` 与 `OpenSSL` 是子模块，本地 clone 里是空目录，打包/CI 都要先 `git submodule update --init`，否则编不过）。
  - Archive 命令：`xcodebuild archive -archivePath archive -scheme LiveContainer -project LiveContainer.xcodeproj -sdk iphoneos -arch arm64 -configuration Release`（scheme 名仍是 `LiveContainer`，内部 target 名按“先别动”没改，所以产物仍叫 `LiveContainer.ipa` 与 `LiveContainer+SideStore.ipa`，见下条）。
  - 之后 `sh .github/build_github.sh` 出 IPA，两个产物都作为 artifact 上传。
- **注意**：scheme / target 名没改名，所以 CI 产物文件名还是 `LiveContainer.ipa`，不是 `SealBox.ipa`。要不要把 scheme 也改成 SealBox（产物随之改名），等 MJ 定；改 scheme 是小事，但会动 pbxproj 里的 scheme 配置，留到他拍板再做。
- **打包提醒**（沿用 v1）：只打源码树，不要把 `.git` 打进去；LICENSE（AGPL-3.0）必须随包带上；包里 `litehook` / `OpenSSL` 子模块是空目录，拿到包的人须先 `git submodule update --init`。

---

## 7. 待 MJ 定的事

1. **Team ID**：`xcconfigs/Global.xcconfig` 的 `DEVELOPMENT_TEAM` 仍是占位 `AAAAA11111`。要真机编译/发版必须填真的 Team ID，并在开发者账号里建 App ID 与描述文件（主 App + LiveProcess + 两个扩展各一份）。
2. **App 图标正式版**：现在是纯色占位（§5），正式图标要 MJ 给或定稿后替换。
3. **Scheme 改名**：CI 产物现在仍叫 `LiveContainer.ipa`，要不要把 scheme 改成 SealBox 让产物也叫 `SealBox.ipa`，等他定。
4. **AGPL 开源**：LICENSE 是 AGPL-3.0，分发必须提供对应完整源码，不能做成闭源产品。是否接受开源，等他拍板。
5. **灵动岛**：App 侧 request/update/end 已写好，但岛上显示要 Widget Extension（新 Bundle ID + 签名），做不做等他定。
6. **SideStore 改 Seal / JIT 启用改仅 Seal**：先不改，v1 保持上游原样，后面再根据实际来改（已定）。

---

## 8. 改动文件清单

共 84 个 tracked 文件改动 + 2 个新文件（`LCDesktopWallpaper.swift`、`SEALBOX_RENAME.md`）。`INVENTORY.md` 未跟踪，不在本次提交里。

- 改名核心：`xcconfigs/Global.xcconfig`、`LiveContainer/Info.plist`、`LiveProcess/Info.plist`、`entitlements.xml`、`entitlements.catalyst.xml`、`LiveProcess/LiveProcess.entitlements`、`ShareExtension/ShareExtension.entitlements`、`LaunchAppExtension/LaunchAppExtension.entitlements`、`LiveContainer.xcodeproj/project.pbxproj`。
- 改名代码：`LiveContainer/LCBootstrap.m`、`LiveContainer/LCSharedUtils.m`、`LiveContainer/Tweaks/SecItem.m`、`LiveContainerSwiftUI/Models/LCAppInfo.m`、`LiveContainerSwiftUI/Models/LCAppModel.swift`、`LiveContainerSwiftUI/Utilities/LCUtils.m`、`LiveContainerSwiftUI/Utilities/LCUtilsExtensions.swift`、`LiveContainerSwiftUI/Utilities/Shared.swift`、`LiveContainerSwiftUI/Views/AppList/LCAppBanner/LCAppBannerViewController.swift`、`LiveContainerSwiftUI/Views/AppList/LCAppListView.swift`、`LiveContainerSwiftUI/Views/AppList/LCDownloadView.swift`、`LiveContainerSwiftUI/Views/AppList/LCWebView.swift`、`LiveContainerSwiftUI/Views/LCTabView.swift`、`LiveContainerSwiftUI/Views/Settings/DataManagement/LCDataManagementView.swift`、`LiveContainerSwiftUI/Views/Settings/LCJITLessDiagnoseView.swift`、`LiveContainerSwiftUI/Views/Settings/LCMultiLCManagementView.swift`、`LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift`、`LaunchAppExtension/LaunchAppExtension.swift`、`MultitaskSupport/MultitaskDockView.swift`、`ShareExtension/ShareExtensionViewModel.swift`、`ShareExtension/ShareExtensionViews.swift`、`ShareExtension/main.m`、`SideStoreSupport/SideStore.swift`、`SideStoreSupport/SideStoreHooks.m`、`TweakLoader/UIKit+GuestHooks.m`。
- 文案：`Resources/Localizable.xcstrings`、39 个语种的 `Resources/*.lproj/InfoPlist.strings`。
- 图标占位：`Resources/Assets.xcassets/AppIcon.appiconset/`（3 张）、`Resources/Assets.xcassets/AppIconGrey.appiconset/`（3 张）、`Resources/AppIconGrey60x60@2x.png`、`Resources/AppIconGrey76x76@2x~ipad.png`。
- 壁纸/主题新文件：`LiveContainerSwiftUI/Views/AppList/LCDesktopWallpaper.swift`；接入：`LiveContainerSwiftUI/Views/AppList/LCAppListView.swift`、`LiveContainerSwiftUI/Views/AppList/LCDesktopGridCell.swift`。
- 真实删除：`LiveContainerSwiftUI/Models/LCAppModel.swift`（新增 `uninstallFiles`）、`LiveContainerSwiftUI/Views/AppList/LCAppBanner/LCAppBannerViewController.swift`（`uninstall()` 改调共用函数）、`LiveContainerSwiftUI/Views/AppList/LCAppListView.swift`（`deleteDesktopApp` 改真删）、`LiveContainerSwiftUI/Views/AppList/LCDesktopIcon.swift`（共享 App 不可删）。
