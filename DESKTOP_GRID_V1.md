# 独立容器 App — 桌面网格 v1 开发报告

- **分支**：`desktop-grid-v1`
- **基线**：`9108ae624ea001f7d7696d48407f890b48fa2653`（3.8.11，AGPL-3.0，冻结基线）
- **日期**：2026-11-08
- **状态**：代码已写完，未编译、未验证可构建（本机 Linux，无 Xcode/Swift），须在 Mac / GitHub Actions（Xcode 26.2）上验证

> 上游已前进：`git fetch` 显示 `origin/main` 已到 `53e83476f85837f0dfe1199ff402853cd0514d9b`（"Fix Backuground Continuous Processing Tasks. #1710"）。**没有 rebase**，仍以 `9108ae62` 为冻结基线开发。是否跟进上游，待 MJ 决定。

## 1. 改了哪些文件

| 文件 | 行数 | 一句话 |
|---|---|---|
| `LiveContainerSwiftUI/Views/AppList/LCAppListView.swift`（改） | 1258 → 1783（+634 / −109） | 列表改成 4 列分页网格 + 编辑模式 + Dock + 系统图标 + 灵动岛接线；数据层、搜索、排序、安装逻辑原样保留 |
| `LiveContainerSwiftUI/Views/AppList/LCDesktopIcon.swift`（新，310 行） | — | 统一图标身份（IPA App + 系统页）与持久化存储：桌面顺序、Dock 成员、启动次数 |
| `LiveContainerSwiftUI/Views/AppList/LCDesktopGridCell.swift`（新，151 行） | — | 纯 SwiftUI 小格子：60pt 图标 + 一行名字 + 抖动 + − 号 + 锁标记；另含藏 Tab Bar 的 helper |
| `LiveContainerSwiftUI/Views/AppList/LCDesktopDockView.swift`（新，136 行） | — | 自画磨砂 Dock（`.ultraThinMaterial`，圆角），最多 4 个，无名字、无角标 |
| `LiveContainerSwiftUI/Views/AppList/LCDesktopDrag.swift`（新，208 行） | — | 拖动状态机 + 四个 DropDelegate（格子、页空白处、屏幕边缘、Dock） |
| `LiveContainerSwiftUI/LiveActivity/LCContainerLiveActivity.swift`（新，174 行） | — | 容器自身的最小 Live Activity：Attributes + request / update / 延迟 end |
| `LiveContainer/Info.plist`（改，+2 行） | — | 加 `NSSupportsLiveActivities = YES` |

没有动：`LiveContainer/` 核心加载器、`LiveProcess`、`TweakLoader`、`ZSign`、`SideStoreSupport`、`MultitaskSupport`、Seal 仓库、Bundle ID / Team ID / 签名配置（留 upstream 原值，见 §7）。

### 为什么网格里不复用 LCAppBanner

`LCAppBanner` 是 `UIViewControllerRepresentable`，包着 UIKit 的 `LCAppBannerViewController`（上下文菜单、运行按钮、双击进设置、卸载流程），是为纵向列表做的通栏行。网格需要的是 60pt 纯 SwiftUI 图标格：banner 塞不进 `LazyVGrid`，还会把 UIKit 手势和尺寸行为带进网格。网格格子只复用了 banner 也用的东西：`LCAppModel` + `appInfo.iconIsDarkIcon(_:)` + 现成的 `IconImageView`（圆角 = 宽 × 0.2667，和 banner、自定义排序列表一致）。`LCAppBanner` 两个文件仍在树里、仍能编译，现在桌面不再用它，删不删是后续决定。

## 2. 桌面网格

- `LCAppListView` 的 `NavigationView + ScrollView + LazyVStack + LCAppBanner` 列表改为 4 列 `LazyVGrid`（`LCDesktopGridCell`：图标 60pt + 一行名字，超长截断不换行、字号可缩到 0.7 倍）。
- 复用 `filteredApps / sortedApps`（`LCAppSortManager`）、搜索（`.searchable` 原样）、隐藏 App 规则（`LCStrictHiding` + 解锁态才进网格）、安装逻辑（`choosingIPA / betterFileImporter / installIpaFile` 一字未改）。
- 排序菜单（toolbar 右侧）保留；桌面手动顺序与排序器的 `appSortType` 是两套东西（见 §6 已知缺口）。

## 3. 编辑模式

- `isEditing` 状态。长按图标 0.5 秒进编辑：图标小角度来回旋转抖动（±1.2°，0.12 秒往返），每个 IPA 图标左上角出红色 −，顶部左上角出只有 `+` 号的胶囊按钮（点它触发已有的 `choosingIPA` / `betterFileImporter` 选 `.ipa` / `.tipa`，不重写导入），顶部右上角出 `✓`（点它退出编辑）。
- 常态下没有 `+` 和 `✓`。原来的 `+` 菜单随之拿掉：**副作用——工具栏里的「从 URL 安装」入口也没了**，仍可通过 `install` 深链和应用内 web view（itms-services）到达。如需保留，v1.1 把 URL 安装放进编辑模式的 `+` 菜单里。
- 点 − 弹确认（复用 `lc.appBanner.confirmUninstallTitle / confirmUninstallMsg / uninstall` 文案），确认后调已有的 `removeApp(app:)`。**重要缺口：`removeApp` 只把模型从 `sharedModel.apps / hiddenApps` 里删掉，不删文件**。删 bundle 和数据文件夹的代码在 `LCAppBannerViewController.uninstall()` 里，网格没接。也就是说 v1 的删除只是把 App 从桌面拿掉，文件还留在磁盘上。接文件清理是后续项，不要当成已删干净。
- 系统图标（源/设置/插件）没有 −：它们是固定入口，删不掉。Dock 里的 − 含义不同（见 §5）。
- 编辑模式下点按图标不启动（和 iPhone 桌面一致）。

## 4. 分页与页点

- **分页选择：`TabView + .tabViewStyle(.page)`，不用横向 ScrollView。** 原因：分页、选中绑定（给页点用）、滑动翻页在 iOS 15 部署目标上就能用；ScrollView 分页要 iOS 17 的 `scrollTarget` API，会抬最低版本。系统页点关掉（`.page(indexDisplayMode: .never)`），用自己画的点。
- 每页 24 个（4 列 × 6 行，不含 Dock）。编辑模式下也能切页。
- **页点选择：自己画一排圆点，不用系统 PageTabViewStyle 自带的点。** 原因：系统点的样式和位置不能保证对齐 Dock 上面，而且点不了；自己画的点居中、能点按跳转。当前页亮色实心点，其他页灰色点，翻页时亮点跟着变；只有一页时不显示。
- **页点数量动态算，不写死：`ceil(总图标数 / 24)`，总图标数 = IPA 图标 + 源/设置/插件 3 个系统图标。** 效果图里的 5 个点只是占位。图标增减、跨页拖动、删除 App 后页数实时变；最后一页的 App 全被删光/移走后那一页消失、页点少一个（`currentPage` 越界时自动 clamp 到最后一页）。
- Dock 固定在底部（`safeAreaInset`），不跟着翻页。

## 5. 拖动（含 Dock 自由拖入拖出）

- 纯 SwiftUI `onDrag / onDrop`，无第三方拖拽库。拖动载荷是图标 id 字符串（`UTType.text`）；拖动中的 id 同步存在 `LCDesktopDragState` 里，因为 DropDelegate 的 `DropInfo` 是异步的，不能在 `dropEntered / performDrop` 里同步读 id。
- 同页排序：拖到目标格子前插入，被挤开的图标让位；目标格子在悬停时显示虚线空位（图标本体变透明、描出虚线圆角框），不是静默换位。
- 跨页拖动：拖动时屏幕左右边缘出现 28pt 隐形热区，悬停 0.7 秒自动翻一页，继续悬停继续翻；松手落到目标页对应位置。拖到某页空白处可落位（含最后一页空白处）。
- **Dock 自由拖入拖出（本条为准，上一条"Dock 不接受手动拖入"已作废）：**
  - 网格图标可拖进 Dock，Dock 图标可拖回网格。
  - Dock 最多 4 个：拖第 5 个进来时，Dock 里排最后的那个自动回网格末尾，不丢、不删 App。
  - 从 Dock 拖出后留空位，不自动拿下一个最常用 App 来补；一旦用户手动拖过，手动顺序优先，启动次数只做初始填充（`LCDesktopDockManuallyEdited` 标志位）。
  - 拖动时 Dock 区域高亮（蓝色描边）+ 空位虚线提示。
  - Dock 里的 − 是"移出 Dock、回网格"，不是删除 App；删除 App 只能用网格里的 −。
  - Dock 内排序（Dock 里两个图标换位）未做，见 §8。
- **手势冲突处理：**
  - 编辑模式下点按启动失效（格子的 `onTapGesture` 直接 return），点按不会误启动。
  - 长按 0.5 秒进编辑；`onDrag` 在 iOS 上本身要先按住一会儿才起拖，所以常态下长按先进入编辑、同一触摸可继续拖；快速横滑不进编辑、交给分页器的翻页手势。
  - 搜索时禁用拖动：搜索只显示过滤后的子集，在子集里排顺序会弄坏持久化的全量顺序。
  - 拖动取消（手指抬在任何落点之外、或切后台）时，已落点的路径都会调 `endDrag()`；切后台时 `scenePhase` 变化也会清拖动状态。残留风险见 §6。
- **持久化（全部 App Group UserDefaults，和 `LCAppSortManager` 同一个 store，无新数据库）：**
  - `LCDesktopIconOrder`（[String]）：桌面顺序。IPA id 格式与排序器一致（`"bundleId:relativePath"`，`LCAppSortManager.getUniqueIdentifier`）；系统图标 id 为 `sys:sources` / `sys:tweaks` / `sys:settings`。新装 App 追加到末尾，已删 App 的 id 清理掉。
  - `LCDesktopDockOrder`（[String]）：Dock 成员与顺序。
  - `LCDesktopDockManuallyEdited`（Bool）：用户是否手动拖过 Dock。
  - `LCDesktopLaunchCounts`（[String: Int]）：启动次数，只做 Dock 初始填充（最常用 4 个）。

## 6. 系统页图标（源 / 设置 / 插件）

核实 `LCTabView.swift` 的 4 个 Tab：源（`LCSourcesView()`，`books.vertical`，`multiLCStatus != 2` 时才有）、应用（`LCAppListView()`）、插件（`LCTweaksView()`，`wrench.and.screwdriver`，`multiLCStatus != 2` 时才有）、设置（`LCSettingsView()`，`gearshape.fill`）。"应用"本身除外（应用就是桌面这一页），其余 3 个各做一个桌面图标：

| 图标 | 对应现有 View | 样式 |
|---|---|---|
| 源 | `LCSourcesView`（`LiveContainerSwiftUI/Views/LCAltStoreSourcesView.swift:483`） | 蓝底 + `books.vertical` |
| 插件 | `LCTweaksView`（`LiveContainerSwiftUI/Views/LCTweaksView.swift:394`） | 橙底 + `wrench.and.screwdriver` |
| 设置 | `LCSettingsView`（`LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift:35`） | 灰底 + `gearshape.fill` |

- 圆角单色图标 + 下面一行名字，像系统 App 图标，不是列表行。
- 点图标打开对应页面，**复用现有 View 原样，不重写源/设置/插件页面的内容和逻辑**。
- **打开方式：`fullScreenCover`（item 绑定），三选一的决定。** 不用 `NavigationLink`：三个 View 各自包着自己的 `NavigationView`（`LCSourcesView:496`、`LCTweaksView:396`、`LCSettingsView:83`），嵌套 NavigationView 会出问题；不用普通 sheet：这三个是完整的应用分区、不是临时弹窗，全屏更接近原来 Tab 的感觉。
- **返回方式：导航栏右上角 Done 按钮**（`lc.common.done`）。全屏 cover 没有下滑关闭，Done 是唯一明确出口，不会把用户困住。
- 拖动与 IPA 图标同一套逻辑：同页排序、跨页拖动、拖入拖出 Dock、同一套顺序存储（`LCDesktopIconOrder`，系统图标 id 混在同一个数组里）。Dock 里也可以放这 3 个图标，同样最多 4 个、拖第 5 个进来挤出最后的。
- 底部系统 Tab Bar 藏掉（Apps 页用 `.toolbar(.hidden, for: .tabBar)`，iOS 16+ API；iOS 15 上不生效、Tab Bar 会留着，见 §6）。这 3 个图标就是替代 Tab 的入口，不留两套入口。
- `multiLCStatus == 2` 时源和插件图标不出现（和 `LCTabView` 的 Tab 显示条件一致），设置图标常在。

## 7. 状态栏与灵动岛

### 状态栏

什么都没画、什么都没加：没有假状态栏，没有 `prefersStatusBarHidden` / `batteryLevel` / `NWPathMonitor`。系统状态栏原样留着，时间/信号/电池由系统显示。效果图里信号满格只是画法，代码里没有写死假信号。

### 灵动岛 Live Activity（容器自身，不是客 App 的）

只做两件事：IPA 安装进度、客 App 启动中。

**分步实现：**

1. **Attributes 定义**（`LiveContainerSwiftUI/LiveActivity/LCContainerLiveActivity.swift`）：`LCContainerLiveActivityAttributes: ActivityAttributes`，含 `appName: String`、`kind: Kind`（`.install` / `.launching`）；`ContentState` 含 `progress: Double`（0–1）、`statusText: String`、`isFinished: Bool`。`import ActivityKit` 只出现在这个文件里；类型标 `@available(iOS 16.1, *)`，全部调用点包在 `if #available(iOS 16.1, *)` 里。
2. **request 时机**：开始安装（`installIpaFile` 入口，名字先取 IPA 文件名）或开始启动（网格/Dock 点按 `launchDesktopApp`、深链 `launchAppWithBundleId`）时 `Activity.request`。同一时间只跑一个活动，新请求先结束旧的。
3. **update 时机**：安装进度变化时（`installProgress` 的 KVO 回调，`fractionCompleted` → `updateProgress`）；启动中只发一次初始态。
4. **end 时机**：完成后**不立刻 end**——先 `update` 到完成态（`progress = 1.0`、`isFinished = true`），保留约 8 秒再 `end(dismissalPolicy: .default)`。参考 Seal 配对岛的教训：立刻结束的话系统会马上把活动从岛上撤下，用户看不到"完成"。出错/取消路径走 `endNow()`（立即结束，无完成态）。
5. **Info.plist**：主 App `LiveContainer/Info.plist` 加 `NSSupportsLiveActivities = YES`。
6. **权限**：Live Activity 不需要额外 entitlement，已核实，主 App entitlements 文件没动。

**两个诚实说明：**

- **客 App 自己的 Live Activity 做不了。** 客 App 没装在系统里，系统只认容器 App 这一个 Bundle ID。能做的只有容器自身的活动。
- **这个文件还不能在岛上画出东西。** Live Activity 是在 App 里 request、由 Widget Extension 渲染的：Attributes 定义必须在 App 和 Widget 两边逐字共享，Widget 提供 `ActivityConfiguration`（灵动岛 + 锁屏 UI）。本 Fork 没有 Widget Extension target，所以现在只能 request 活动、没有岛 UI 可显示。**缺口 TODO（WidgetExtension）：新建 Widget Extension target，把 Attributes 定义移到两边共用的文件/共享 group，加 `ActivityConfiguration`。这需要新 Bundle ID + 签名，待 MJ 定（见 §7）。不要把现在这个版本说成"岛上已能显示"。**
- 只做最小版：没有锁屏小组件、没有推送更新。

## 8. 没做 / 待定清单

- 文件夹（图标分组）。
- Dock 内部排序（Dock 里两个图标直接换位）。
- 真实信号格数（代码里不读信号；效果图满格只是画法）。
- 系统图标隐藏/删除（源/设置/插件图标是固定入口，网格里无 −；Dock 里的 − 只是移出 Dock）。
- 客 App 自己的 Live Activity（做不了，见 §7）；锁屏小组件；推送更新；Widget Extension（待 MJ 定，见 §7）。
- 桌面顺序与 `LCAppSortManager` 的自定义顺序（`LCCustomSortOrder`）是两套存储：桌面拖动不写回 `LCCustomSortOrder`，列表排序器的自定义排序也不影响桌面。后续如要统一，需再定。
- 搜索时 Dock 里的 App 不进搜索结果（搜索只过滤网格图标）。
- **内置 SideStore 改 Seal、JIT 启用改仅 Seal：已定先不改，待后续根据实际决定。** v1 保持上游原样：没有动 `SideStoreSupport`、没有删内置 SideStore、没有改 `JITEnablerType`、没有加 Seal 的 Scheme。
- v1 删除只调 `removeApp`、不删 bundle/数据文件（见 §3），文件清理是后续项。

## 9. 已知缺口（真机上要重点验的）

1. **拖动取消后拖动状态可能残留**：落到格子/页空白/Dock 上都会清状态；但手指抬在页点、计数文字等无落点区域时，没有 DropDelegate 会触发，`draggedID` 可能残留到下一次拖动开始（影响只限被拖图标半透明 + 边缘热区可见）。切后台会清。真机验证时重点试"拖起来、抬在页点上"。
2. **手势仲裁是系统调解的**：长按进编辑 + `onDrag` 起拖 + 横滑翻页三者不打架，是按 iOS 常规行为设计的，本地验不了，真机重点试"快滑翻页"和"按住拖动"是否各走各的。
3. **Tab Bar 隐藏是 iOS 16+ API**（`.toolbar(.hidden, for: .tabBar)`）：iOS 15 设备上 Tab Bar 会留着，和桌面图标并存。部署目标是 iOS 15.0，如需覆盖 iOS 15，得另想办法。
4. **抖动动画**是 `repeatForever` 的简易实现，真机看是否顺滑、有无残影。
5. **边缘自动翻页的 0.7 秒定时器**在真机手感上可能要调（太慢/太快）。
6. **安装活动的完成态**：安装成功路径会 `finish`；但 `installIpaFile` 里中途 return 的路径（如鉴权失败、用户取消替换）不会 `finish`/`endNow`，活动可能挂起——`startInstallApp` 的 catch 里有 `endNow`，但取消替换的 return 路径没有。后续补。
7. **版本号**：主 App `Info.plist` 是 3.8.11，`project.pbxproj` 里各 target 的 `MARKETING_VERSION` 是陈旧的 1.0（上游原样），没改、没动。发版前要不要统一，待定。

## 10. 待 MJ 定的事

1. **新 Bundle ID**：独立容器 App 不能用上游的 `com.kdt.livecontainer$(DEVELOPMENT_TEAM_SUFFIX)`。代码里没改 ID（注释里标了 TODO），等 MJ 定新 ID 后再改（含 Team ID、签名配置、App Group）。
2. **是否接受 AGPL 开源**：现版本许可证是 AGPL-3.0（2025-10-25 由 Apache 2.0 换成，commit `ba84054`）。按 AGPL 分发就要开源、带 LICENSE 和源码说明；如果不接受，得退回 2025-10-25 之前的 Apache 快照、丢一年修复（含 iOS 26 相关），不推荐。
3. **App Group 方案**：桌面顺序/Dock/启动次数存在 App Group UserDefaults（沿用排序器已有的 store）。App Group ID 随新 Bundle ID 走，等第 1 条定了再定。
4. **Widget Extension 做不做**（灵动岛真正显示的前提，见 §7）：要做就得新 Bundle ID + 签名 + 共享 Attributes 文件。
5. **上游跟进**：`origin/main` 已前进到 `53e83476`，是否 rebase，跟不跟。

## 11. 打包说明（给 MJ 的源码包）

- **不要自己打包发给他。** 最终分支名、commit、改动清单以本报告为准，等主 agent 打包。
- **分支**：`desktop-grid-v1`；**代码 commit**：`15b34d2`（"Desktop grid v1: 4-column paged grid, edit mode, Dock, system icons, Live Activity"，7 个文件，+1615 / −109）；本报告是该分支的 head 提交（`git log --oneline -1` 为准）。
- **不要把 `.git` 整个打进去**（太大）：只打源码树，例如 `git archive` 打分支快照。
- **子模块（重要）：包里不含子模块源码。** `litehook` 和 `OpenSSL` 是 git 子模块（gitlink：`litehook @ a7e9f599`、`OpenSSL @ 623c84da`），本机 clone 里两个目录都是空的、未初始化（`git submodule status` 前缀为 `-`）；`fishhook` 只在 `.gitmodules` 里有条目，index 里没有 gitlink、本地也没有目录。`git archive` 默认不含子模块内容，所以打出来的源码树里 `litehook/`、`OpenSSL/` 是空的——拿到包的人要先 `git submodule update --init`（或打包时另行把子模块打进去），否则编不过。不要把空目录当成"已含子模块"发出去。
- **LICENSE 是 AGPL-3.0**：仓库根目录的 `LICENSE`（34,523 字节，GNU AGPL v3）必须随包带上；按 AGPL 打包分发要带上 LICENSE 和源码说明（源码从哪里来、对应哪个 commit、按 AGPL 取得源码的途径）。

## 12. 下一步验证步骤

1. **Mac / GitHub Actions（Xcode 26.2）上先构建一次原样 3.8.11**（基线能编过），再构建改后版，对比。
2. 静态检查已做（本机）：6 个文件括号配平全过；`import ActivityKit` 只在 Live Activity 文件；全部调用点有 `if #available(iOS 16.1, *)`；新 switch 全分支都有 `return`（无裸值 + 语句混用的退化陷阱）；`@Published` 状态只在主线程侧改（`refreshDock` 包在 `MainActor.run` 里）；版本号没动。**但这些都不是编译，Swift 语法、类型、ViewBuilder 组合仍须 Xcode 验。**
3. 真机验证清单：4 列网格 + 名字截断；长按进编辑/抖动/−/+  /✓；24 个一页翻页 + 页点跟着变 + 页数动态增减；同页拖动、跨页拖动（边缘翻页）、拖到最后一页空白处、拖入拖出 Dock、第 5 个进 Dock 挤出最后的、拖出留空位；重启后顺序/Dock 不变；系统图标三页打开 + Done 返回；安装进度与启动中的岛活动（需 Widget Extension 才能看到岛 UI，见 §7）；iOS 15 设备 Tab Bar 是否残留；删除后文件是否还在（预期还在，见 §3）。
4. 工具栏 URL 安装入口没了（见 §3），确认 MJ 接受或在 v1.1 补回。

## 附：git diff --stat

```
LiveContainer/Info.plist                              |   2 +
LiveContainerSwiftUI/Views/AppList/LCAppListView.swift | 743 ++++++++--------
新文件：LCDesktopIcon.swift（310 行）、LCDesktopGridCell.swift（151 行）、
LCDesktopDockView.swift（136 行）、LCDesktopDrag.swift（208 行）、
LiveContainerSwiftUI/LiveActivity/LCContainerLiveActivity.swift（174 行）
```
