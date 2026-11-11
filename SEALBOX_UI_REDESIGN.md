# SealBox 首页重做报告：虚拟手机 Box

分支：`SealBox`（基线：改名 + scheme 改名提交 `1c19d58`）
本次提交：见 `git log`（首页重做 + 默认壁纸 + 本报告）
日期：2026-11-08

**未编译**：本机 Linux，无 Xcode，全部只做了静态检查，须 Mac / GitHub Actions（Xcode 26.2）构建验证（见“验证”）。

---

## 0. 总纲：Box 是什么

SealBox 不是在 LiveContainer 界面上加一层桌面，而是**一台装在 App 里的虚拟手机**：

| 部分 | 按手机的什么逻辑走 |
|---|---|
| 首页 = 手机主屏幕 | 全屏壁纸（默认雨天自拍那张）、4 列图标、底部 Dock 固定死、长按进编辑（左上 +、右上 ···）、切页、页点。常态下不要出现任何 App 列表、标题、搜索栏、工具栏 |
| 客 App 点开 | 在这台虚拟手机里打开：点桌面图标启动，运行，退出后回到手机桌面，不要跳回 LiveContainer 的列表页。启动/返回的机制沿用上游 `runApp`（未动）；变的是回到哪里——现在回到的是手机桌面。没有新增悬浮 Home 键 |
| 系统页（源/设置/插件） | 按手机里打开一个 App 的方式走：点桌面图标打开，全屏，像手机里打开设置一样；返回靠 Done 按钮（各页自带的导航栏返回键），不走 TabView，不出现 LiveContainer 的列表壳子 |
| 状态栏 / 壁纸 / Dock / 图标 | 按真实手机的规矩来：系统状态栏不动；壁纸按真实桌面壁纸自动适应（§4）；Dock 固定死（§5）；图标 60pt、名字一行截断、带阴影。文件夹没做（以前也没做） |

前面定的细节（桌面 4 列、Dock 固定、壁纸自动适应、默认壁纸、长按出 + 和 ···、真删除）都按这条总纲走。

---

## 1. 拆了哪些 LiveContainer 原版 UI

全部在 `LiveContainerSwiftUI/Views/AppList/LCAppListView.swift` 里拆掉：

| 拆掉的东西 | 原来在哪 | 现在 |
|---|---|---|
| NavigationView 壳子 | 整个 `body` 包在 `NavigationView` 里 | `body` 就是一个 `ZStack`（壁纸 + 网格 + 顶栏 + Dock），没有 NavigationView |
| 大标题「App」 | `.navigationTitle("lc.appList.myApps")` | 无标题 |
| 搜索栏 | `.searchable(text: $searchContext.query)` 常驻 | 删掉；搜索改到 ··· 菜单里（§3） |
| 顶部工具栏 | 5 个 ToolbarItem：`?` 帮助、SideStore 图标、`···`、✓/链接、排序菜单 | 全部删掉。`?` 帮助入口随之没了（`LCHelpView` 文件还在，没再被引用）；排序菜单搬进 ··· 菜单 |
| 导航栏进度条 | `.navigationBarProgressBar(...)`（往导航栏里插 UIProgressView） | 删掉；安装进度改成顶部悬浮小 pill（§2 常态） |
| TabView 底部栏 | `LCTabView` 是 App 根视图，首页用 `.hideDesktopTabBar()` 藏它 | 首页仍用 `.hideDesktopTabBar()` 藏它（iOS 16+；iOS 15 上仍会残留，老缺口，未变）。TabView 本身还在当 App 根（它管深链、崩溃检查、下载提醒），但首页不再有它的壳子 |
| 空态文案「点击加号按钮安装 App」 | `emptyStateView` + `counterFooter`（没装 App 时显示） | 两个 View 整个删掉。没装 App 时桌面就是一张空壁纸，什么文案都没有 |
| App 计数 footer | `counterFooter`（“N 个 App”） | 同上，删掉 |
| 原版列表 LCAppBanner 行 | 列表行 | 首页早就是网格了；这次把 Banner 的导航残留也断了：隐藏的 NavigationLink 删掉，`openNavigationView` / `navigateTo` / `isNavigationActive` 只剩协议要求的空壳（Banner 行已不在首页，无处调用它们） |

三重点击解锁隐藏 App 的手势原来藏在计数 footer 上，footer 删了之后手势改成：常态下三击桌面空白处解锁（`authenticateUser()`）。

### 顺手修掉的两个 LiveContainer 残留

- `LCAppSettingsView.swift:332/346` 用的文案 key `lc.appSettings.hideLiveContainer` / `hideLiveContainerDesc` 在文案库里根本不存在（改名时只改了文案库里的 key，没改代码），`.loc` 找不到就原样返回 key 本身——App 设置页里那个开关原来显示的就是 `lc.appSettings.hideLiveContainer` 这串原文。已改成 `lc.appSettings.hideSealBox` / `hideSealBoxDesc`（文案库里有，英文是 "Hide SealBox from dyld API"）。
- 全仓核对 300 个在用的 `lc.*` 文案 key，改完后 0 个缺失（之前缺的就是上面这两个）。

### 有意保留的 LiveContainer 痕迹（按任务的例外清单）

- 上游仓库链接不动：设置页里的 GitHub `LiveContainer/LiveContainer` 按钮、`hugeBlack`、`khanhduytran0` Twitter 作者行；帮助文案里指向 `github.com/khanhduytran0/LiveContainer/issues` 的 FAQ 链接（文案本身已是 "SealBox FAQ"，链接地址还是上游的，因为 SealBox 仓库里没有对应的 FAQ issue #265）。MJ 如果连作者行也要拿掉，是一处小改动，另说。
- 内部变量名、类名、文件夹名、App Group 数据文件夹名、`hideLiveContainer` 等 plist key、`_LiveContainerPatchBackUp` 备份文件名后缀不动。
- `Dyld.m:708` 的 "Create an issue on LiveContainer GitHub"（崩溃路径里的上游报错串）不动。

---

## 2. 常态 / 编辑模式各长什么样

### 常态（v6 效果图）

- 全屏壁纸（默认雨天自拍那张，§4），什么按钮都没有，只有 4 列网格图标 + 底部磨砂 Dock。
- Dock 里只放导入的 App，无名字无角标。源/设置/插件三个系统图标回到网格里做图标，不放 Dock（修掉了之前截图里的 bug：Dock 初始填充用的候选顺序里含系统图标，没装 App 时 Dock 里就是源/插件/设置三个系统图标；现在填充只用 IPA 的 id，`LCDesktopDockStore.init` 还会把旧存量里的 `sys:` id 清掉、`addToDock` 拒绝系统图标、`dropIconOnDock` 拒绝系统图标拖入，三道防线）。
- 正在安装 IPA 时，顶部出现一个悬浮小 pill：转圈 + 百分比（代替原来的导航栏进度条）。

### 编辑模式（v7 效果图）

- 长按桌面 0.5 秒进编辑，图标抖动、左上角带红色 `−`（点 − 真删，bundle + 数据容器 + 钥匙串，不变）。
- 左上角出 `+` 胶囊（点它选 IPA 导入），右上角出 `···` 胶囊（点它弹菜单）。常态下 `+` 和 `···` 都不显示。
- `···` 菜单里的项：壁纸、主题色（跟随系统 / 深色 / 浅色）、搜索、排序（含“管理自定义排序”）、恢复默认壁纸（红色）、完成。
- 退出编辑：点桌面空白处退出，或 `···` 菜单里的「完成」退出；退出时搜索框收起、搜索词清空。右上角不再放 `✓`。

### 保留的功能（都没丢）

4 列分页（每页 24 个）、页点、拖动排序/跨页/Dock 进出（拖第 5 个进 Dock 时排最后的回网格）、壁纸、主题、点 − 真删、灵动岛接线（安装/启动的 Live Activity）、搜索（改到 ··· 菜单，§3）。

---

## 3. 搜索改到哪了

- 不再常驻搜索栏。编辑模式下点 `···` 菜单里的「搜索」，顶部出现一个悬浮搜索框（放大镜 + 输入框 + × 清空 + 取消），弹出时自动聚焦、键盘升起。
- 搜的是 App 名和 Bundle ID（原来的 `filteredApps` / `debouncedQuery` 逻辑没动）；搜索时系统图标隐藏、拖动禁用（原来就是这样）。
- 点「取消」或退出编辑，搜索框收起、搜索词清空。

---

## 4. 壁纸

### 换壁纸现在是几步

两步：`···` 菜单点「壁纸」→ 系统照片选择器（PHPicker，单张）选一张图 → **选完直接应用**。没有编辑页，没有确认页。

### 编辑页删了

- `LCWallpaperEditView` 整个删掉（裁剪/缩放滑条、亮度滑条、模糊滑条、拖动定位全删）。
- `LCDesktopWallpaperSettings` struct 整个删掉。
- `wallpaper.json` 不再写、不再读：只存图片本身（`SealBoxWallpaper/wallpaper.jpg`）。旧版留下的 `wallpaper.json` 在「恢复默认」时顺带删掉，不留孤儿文件。
- `LCAppListView` 里 `wallpaperEditImage` / `showWallpaperEditor` 两个 state 和编辑页的 fullScreenCover 删干净；选图回调直接调 `wallpaperStore.apply(image:)`。

### 默认壁纸（雨天自拍那张）

- **放哪**：`Resources/Assets.xcassets/DefaultWallpaper.imageset/`，里面是原图 `DefaultWallpaper.jpg`（1008×2304，竖图，913KB）+ `Contents.json`（universal 1x）。选 Assets.xcassets 不选散文件的原因：`Assets.xcassets` 本来就在主 target 的资源里，编包时自动带走，不用改 pbxproj；散放在 `Resources/` 下的文件要逐个进 pbxproj 的资源 phase，容易漏。
- **怎么加载**：`LCDesktopWallpaperStore.bundledDefaultImage` = `UIImage(named: "DefaultWallpaper")`，读主包的 asset catalog。`load()` 时没有自定义壁纸文件就用这张，`image` 恒不为空；`hasCustomWallpaper` 改按“存不存在自定义文件”算，不再按 `image != nil` 算。
- **恢复默认回到哪张**：`resetToDefault()` 删掉 `SealBoxWallpaper/wallpaper.jpg`（+ 旧 `wallpaper.json`），`image` 回到包里的这张雨天自拍，不是纯色/渐变。首次打开没选过壁纸时，桌面就是这张。
- **用户换了壁纸，默认图还在包里**：自定义壁纸只写 App Group 目录下的 `wallpaper.jpg`，包里的 `DefaultWallpaper.jpg` 在 app bundle 里，永远不会被覆盖；恢复默认读的也是包里的那份。

### 壁纸用什么填充方式、横图/竖图/方图怎么处理

- 按 iOS 真实桌面的做法：`Image.resizable().aspectRatio(contentMode: .fill)`，居中、等比铺满，系统自己算，不用用户调裁剪/缩放。
- 横图、竖图、方图都一样：等比放大到盖满屏幕，多余的部分居中裁掉，不拉伸变形、不留白边；不同机型屏幕尺寸不同，也自动适应（`frame(maxWidth: .infinity, maxHeight: .infinity)` + `.clipped()` + `.ignoresSafeArea()`）。
- 图标名字在图上看得清：名字永远带一层阴影（黑 0.55、半径 2、向下 1pt，`LCDesktopGridCell` 里已有，核对过还在），再加主题的遮罩（深色主题盖黑 0.35、浅色盖白 0.20）兜底。

### 主题（不动）

跟随系统 / 深色 / 浅色，存在 App Group UserDefaults 的 `LCDesktopTheme` 里，入口在 `···` 菜单的「主题色」子菜单；壁纸与主题分开存，换一个不丢另一个。

---

## 5. Dock 怎么固定的、键盘弹起时 Dock 怎么办

- Dock 用 `safeAreaInset(edge: .bottom)` 固定在屏幕底部（原来就是这个做法，这次保留并写死）：切页、拖动图标、搜索、壁纸切换、主题切换都不能把它顶下去、压扁、缩小、藏起来。
- Dock 高度固定：`LCDesktopDockView` 里横向 padding、纵向 padding、圆角都是定值，图标固定 56pt，不随内容多少变化；空位平时透明、只在编辑/拖动时显示虚线框。
- 键盘弹起时 Dock 不跟键盘走：`body` 上加了 `.ignoresSafeArea(.keyboard, edges: .bottom)`，键盘升起不改变底部安全区，Dock 原地不动。搜索框在顶部，键盘盖不到它。

---

## 6. 验证

本机 Linux，无 Xcode，**未编译**。以下全部是静态验证，2026-11-08 跑过：

1. 任务要求的 grep（`LCAppListView.swift` 内）：
   - `点击加号按钮安装 App` → **0 条**（空态文案已删干净）
   - `searchable` → **0 条**（常驻搜索栏已删；注释里也不再提它）
   - `navigationTitle` → **1 条**：`JITEnablingModal`（JIT 等待弹窗）里的 `.navigationTitle("lc.appBanner.waitForJitTitle")`——那是弹窗自己的标题，不是首页，保留
   - `搜索` → **2 条**，都是新的搜索 UI：`···` 菜单里的「搜索」项、悬浮搜索框的 `TextField("搜索")`——不是旧搜索栏
2. 死引用 grep（`helpPresent` / `wallpaperEditImage` / `showWallpaperEditor` / `LCWallpaperEditView` / `LCDesktopWallpaperSettings` / `wallpaperStore.settings` / `emptyStateView` / `counterFooter`）→ **0 条**。
3. 括号配平（`{}`/`()`/`[]` 逐文件数）：`LCAppListView.swift` 480/480、651/651、56/56；`LCDesktopWallpaper.swift` 36/36、71/71、2/2；`LCDesktopIcon.swift` 63/63、94/94、21/21。`switch` 全分支：主题 4 个计算属性各 3 分支全有返回值；`LCDesktopIcon` 各 switch 穷举；`flipPage` 方向 switch 两分支齐全。
4. 文案 key 全量核对：代码里用的 300 个 `lc.*` key 在 `Localizable.xcstrings` 里 **0 个缺失**（修掉的两个见 §1）。
5. `LiveContainer` 字样扫查：Swift 代码里剩下的都是内部标识（类名/变量名/文件夹名/路径/`hideLiveContainer` plist key）和上游仓库链接（§1 例外清单）；界面上能看到的已全部是 SealBox，另见 §1 顺手修掉的两处。
6. 默认壁纸资源：`DefaultWallpaper.imageset/DefaultWallpaper.jpg`（1008×2304）+ `Contents.json` 已进树；`Assets.xcassets` 在主 target 资源里，不用改 pbxproj。

### 须 GitHub Actions 验证的事（真机/CI 清单）

- 编过：新 body 没有 NavigationView 后，`.toolbar(.hidden, for: .tabBar)` 在 LCTabView 里的 TabView 层级下是否还藏得住 Tab Bar；iOS 15 上 Tab Bar 残留的老缺口是否还在。
- 首页是不是纯桌面：无标题、无搜索栏、无工具栏；空桌面只有壁纸。
- 编辑模式：长按进编辑，左上 `+`、右上 `···`；点空白处 / 菜单「完成」退出；搜索框弹出、聚焦、键盘升起时 Dock 不动。
- 壁纸：首次打开是雨天自拍那张；换一张图直接应用；恢复默认回到雨天自拍；横图/竖图/方图都铺满不拉伸。
- Dock：没装 App 时 Dock 是空的（不再出现源/插件/设置）；旧存量里有系统图标的 Dock，升级后系统图标回网格。
- 设置页里「Hide SealBox from dyld API」开关显示正常（之前显示的是 raw key）。

---

## 7. 改动文件清单

- `LiveContainerSwiftUI/Views/AppList/LCAppListView.swift`：body 重写（去 NavigationView/标题/搜索栏/工具栏/空态/计数器）、编辑模式顶栏（+ / ··· 菜单：壁纸、主题色、搜索、排序、恢复默认、完成）、悬浮搜索框（自动聚焦）、安装进度 pill、退出编辑（点空白处 / 菜单完成）、Dock 只放 IPA（`dockDisplayIcons` 过滤、`desktopAppIDs`、`dropIconOnDock` 拒系统图标）、`desktopBackgroundView` 改 aspect fill、删 `emptyStateView` / `counterFooter` / 帮助入口。
- `LiveContainerSwiftUI/Views/AppList/LCDesktopWallpaper.swift`：删 `LCWallpaperEditView` 与 `LCDesktopWallpaperSettings`，只存 `wallpaper.jpg`，`wallpaper.json` 只删不读；新增包内默认壁纸 `bundledDefaultImage`；`hasCustomWallpaper` 改按文件存在算。
- `LiveContainerSwiftUI/Views/AppList/LCDesktopIcon.swift`：`isSystem` / `isSystemID(_:)`；Dock store 启动时清掉旧存量的 `sys:` id，`addToDock` 拒绝系统图标。
- `LiveContainerSwiftUI/Views/AppList/AppSettings/LCAppSettingsView.swift`：两个文案 key 改成 `hideSealBox` / `hideSealBoxDesc`。
- `Resources/Assets.xcassets/DefaultWallpaper.imageset/`（新增）：`DefaultWallpaper.jpg` + `Contents.json`。
- 本报告 `SEALBOX_UI_REDESIGN.md`。
