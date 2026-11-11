# SealBox Dock 修复报告（SEALBOX_DOCK_FIX.md）

分支：`SealBox`，本批基于 `00cb44f`（上游 head 为 `6b9995b`，期间并行提交加了 Widget Extension，见 §8 第 1 项），本次提交 `40f47b9`。**不要推送，不要打包。**

本批一次做完 7 件事：毛玻璃 Dock、顶部安全区、空 Dock 占位、左滑返回、回桌面、长按修复、拖动丝滑；最后按 MJ「虚拟手机桌面」总纲逐项核对真假。全部只做了静态检查（见文末「未编译」）。

---

## 1. 毛玻璃 Dock

### 原来是什么材质

Dock 本来就已经是 `.ultraThinMaterial`（`LCDesktopDockView.swift`，圆角 26，56pt 图标）——不是实心灰白条。grep 确认：Dock 文件里没有任何不透明底色填充（`Color.white` / `Color.gray` 只出现在注释和描边里，见下「验证」）。MJ 真机截图里底部根本没有 Dock，**不是材质错了**，是空 Dock 在深色壁纸底部几乎看不见：毛玻璃本身没有颜色，空条上没有任何图标、没有任何描边，雨天壁纸底部又是深色，磨砂条和壁纸糊成一片。静态检查无法证明它当时到底有没有渲染（也可能是截图裁切），所以按「让空条按构造就可见」修，而不是猜一个渲染原因。

### 改成什么

- 底仍是 `.ultraThinMaterial`（不变），圆角 26（不变），壁纸在 Dock 后面透出来、被磨砂糊住（不变）。
- 新增：**1pt 白色描边** `Color.white.opacity(0.25)`（`RoundedRectangle(cornerRadius: 26).stroke`），只画轮廓、不填色，空条也有边界。
- 新增：**固定最小高度 76pt**（56pt 图标 + 上下各 10pt 内边距），空 Dock 也留一条 76pt 的毛玻璃条，不会塌到 0。
- Dock 图标拖起时的抬起效果同步改成和网格一样（见 §7）。

### Dock 固定死（不变）

- 仍是 `.safeAreaInset(edge: .bottom)`，仍是 `.ignoresSafeArea(.keyboard, edges: .bottom)`——键盘弹起不跟键盘走。
- 切页是 `TabView(.page)` 里的内容翻页，Dock 在 safeAreaInset 里，不跟翻页；搜索是悬浮框，不压 Dock；拖动不改 Dock 的 frame。
- 唯一改动：Dock 文件里 `onDrag` 现在只在编辑模式挂载（见 §6），不影响固定。

---

## 2. 顶部安全区（第一行图标顶到状态栏）

### 原因

`desktopPageGrid` 只有 `.padding(.top, 12)`，`TabView(.page)` 的页面内容是 edge-to-edge 布局，网格从屏幕最顶上（y=0）开始排，第一行图标直接盖住状态栏时间（MJ 02:56 截图：时间 02:56 被源图标挡住）。

### 改法

`LCAppListView.swift` 的 body 根改成 `GeometryReader`，读 **`geometry.safeAreaInsets.top`**，给整个内容 VStack 加 `.padding(.top, geometry.safeAreaInsets.top)`。**没有写死数字**：留多少由机型决定（灵动岛机型约 59pt、刘海机型约 47pt、有 Home 键的机型约 20pt），第一行图标从状态栏下面开始排；壁纸仍是全屏（在 ZStack 底层 `ignoresSafeArea`，不受这个 padding 影响）。编辑模式的 `+` / `···` 胶囊同样被顶到状态栏下面（再加原有的 12pt 间距）。

---

## 3. 空 Dock 占位

- 没装 App、Dock 里一个图标都没有时：4 个空位格子（`emptySlot`，56pt 虚线圆角）+ 毛玻璃底 + 1pt 白描边 + 76pt 固定高度，一条空毛玻璃条始终可见，不再直接不显示。
- 拖动时拖到 Dock 上方：蓝色描边高亮（原有 `isDragOver` 描边保留，与白色描边叠加）。

---

## 4. 左滑返回（左侧边栏返回手势）

### 系统页（源 / 设置 / 插件）

- 系统页是 `LCAppListView.swift` 的 `fullScreenCover(item: $systemPage)`，三页各自包 NavigationView，Done 在导航栏右上，**Done 保留**，手势是多一条路。
- 手势接在 cover 内容上：`simultaneousGesture(DragGesture(minimumDistance: 30))`。
- **热区**：起手 x ≤ **24pt**（屏幕最左边约 20pt，取 24pt 容错）；**触发**：向右滑动 **> 80pt**，且横向位移大于纵向位移（`abs(dy) < dx`），才 `systemPage = nil` 回桌面。
- **分先后**：
  - 和页面滚动：`simultaneousGesture`，纵向滚动照常（dx 小，不触发）；横向为主、从左边缘起手的滑动才回桌面。
  - 和图标拖动：手势只挂在 cover 上，桌面图标拖动不在 cover 里，互不干扰；编辑模式拖动图标时系统页根本没打开。
  - 和切页：桌面第一页向右滑不触发（手势只在 cover 上，桌面没有这个手势；已经在桌面了，没地方可回）。
  - 桌面第一页向右滑同时也是切页手势的反方向，TabView 本来就不会翻到第 0 页之前。

### 客 App 里的左滑

MJ 原话是「客 App 里如果有自己的返回栈，先走客 App 自己的返回，没有可返回的就回到桌面」。**客 App 里不做左滑**，原因见 §5：左滑会抢客 App 自己的导航返回栈，而且容器代码无法可靠判断客 App 当前页面是否还有可返回的（没有统一的导航栈接口）。客 App 的回桌面走 §5 的悬浮按钮 + 原生 Home 手势。

---

## 5. 回桌面（进客 App 之后怎么出来）

### 上游原来怎么回

核实了启动与退出路径（`LiveContainer/LCBootstrap.m`、`LiveContainer/LCSharedUtils.m`、`LiveContainerSwiftUI/LiveContainerSwiftUIApp.swift`、`TweakLoader/UIKit+GuestHooks.m`）：

- 经典模式：容器先写 UserDefaults `selected` = 客 App 包路径，再经 LSApplicationWorkspace 打开**自身 Bundle ID**，随后 `raise(SIGKILL)` 自杀；iOS 重新启动 SealBox，启动时 `LiveContainerMain` 读到 `selected` 后**先删掉它**，再由 `invokeAppMain` dlopen 客 App 并跳到它的 main。客 App 在 SealBox 进程内全屏运行，**容器 UI 不存在**，客 App main 返回即进程退出（`return 1`）。
- 所以上游原来**没有进程内「回桌面」按钮**。原生路是：底部上滑（iOS Home 手势）到真机主屏幕 → 在 App 切换器里划掉客 App → 再点 SealBox 图标（因 `selected` 已清，启动即桌面）。
- 多任务模式（`LCLaunchInMultitaskMode`，默认 false）：客 App 跑在独立 LiveProcess 进程的窗口里，窗口铬（`MultitaskAppWindow.swift:115` 的 `vc.terminate()`）提供关闭回容器。
- `TweakLoader/UIKit+GuestHooks.m` 原来没有任何 Home / 悬浮 / 返回手势，只有文件、URL 会话等 Hook。

### 选了哪种方式，为什么

**悬浮返回按钮**（`TweakLoader/UIKit+GuestHooks.m` 新增 `SealBoxInstallHomeButton`）：

- 只有 TweakLoader 的代码在客 App 进程里运行，SwiftUI 手势伸不进去（容器 UI 已不在）；底部上滑是系统 Home 手势，会去真机主屏幕、不是 SealBox 桌面——所以原生手势**不能**直接回 SealBox 桌面，必须在客 App 进程内放一个控件。
- 按钮：44×44 命中区、52×52 的半透明圆（黑底 0.55 透明度 + 白色 `house.fill`），右边缘居中，`windowLevel 1000`（低于系统弹窗层级）、`window.hidden = NO` 显示（**不**抢 key window，不影响客 App 键盘/焦点）。
- **点按 = 回桌面**：写 UserDefaults `selected = @"ui"`（`LCBootstrap.m:730`：`selected == @"ui"` 时清掉 `selected` / `selectedContainer`，走容器 UI），再用 LSApplicationWorkspace 打开自身 Bundle ID（`NSUserDefaults.lcMainBundle` 的 ID，即 SealBox 自己），在 completion 里 `raise(SIGKILL)`——**复用 `LCSharedUtils.m:126-167` 的重启套路**，新进程启动即桌面。
- **可拖动**：按住拖可挪位置（松手前位移 > 12pt 算拖动，不触发回桌面；≤ 12pt 算点按，回桌面），免得挡住客 App 的按钮/游戏操作。
- **只在经典模式客 App**：`lcGuestAppId` 非空且 `!isLiveProcess`；安装在启动后 1 秒（constructor 时 UI 可能还没好），若当时没有 scene，2 秒后重试一次。
- 多任务模式不装按钮（窗口铬已有关闭按钮）。
- `dontInjectTweakLoader` 的客 App 没有按钮，回退路是上游原生方式：底部上滑到真机主屏幕 → App 切换器划掉客 App → 点 SealBox 图标。

### 做不到 / 障碍（写清）

- SwiftUI 手势伸不进经典模式客 App（容器 UI 不存在），所以回桌面不能用手势，只能用进程内控件。
- 客 App 左滑不做（§4）：会抢客 App 自己的返回栈，无法可靠判断是否还有可返回页面。
- 按钮位置在安装时定死（右边缘居中），**旋转屏幕后不会自动跟随**（可能留在旧位置），可拖回；若 MJ 要，下一批可加旋转监听。
- 按钮盖在客 App 界面上，游戏等全屏 App 可能觉得挡事——可拖走；若 MJ 要默认隐藏/可开关，下一批加设置项。
- `openApplicationWithBundleIdentifier:configuration:completionHandler:` 是私有 API 调用（与 `LCSharedUtils.m` 同款写法），编译器会给 warning（方法未在公开头文件声明），Xcode 构建时须确认只是 warning、不是 error。

---

## 6. 长按修复（长按桌面没反应，进不了编辑）

### 原来长按接在哪

- 空白处：**根本没有长按手势**。VStack 上只有 `.onTapGesture`（点空白退出编辑）和 `.onTapGesture(count: 3)`（三击解锁隐藏 App）。
- 图标格子：`LCDesktopGridCell.swift` 有 `.onLongPressGesture(minimumDuration: 0.5)`（进编辑），但同一个格子还挂了 `.onDrag`；Dock 图标同样是 `.onDrag` + `.onLongPressGesture(0.5)`。

### 被谁吃掉了

**`.onDrag` 内部的按住识别器先抢占触摸**。SwiftUI 的 `onDrag` 自带一个按住识别器，它在长按 0.5 秒到之前就先 claim 了触摸，格子自己的 `onLongPressGesture` 永远等不到触发——长按图标只会默默进入「拖动待命」，没有任何反应。空白处则连手势都没有。所以真机上长按哪里都没反应。另有一个次要冲突：图标格子的 `.onTapGesture`（点按启动）和父级 VStack 的 `.onTapGesture`（点空白退出编辑）会同时触发——编辑模式下点图标会悄悄退出编辑（见下）。

### 改后接在哪，为什么这次能触发

- **`.onDrag` 只在 `isEditing` 时挂载**：`desktopPageGrid` 的 `.apply` 里由 `if isSearching || !isEditing { cell } else { cell.onDrag….onDrop… }`；Dock 图标同理（`LCDesktopDockView.dockIcon` 里 `.apply` 包裹 `onDrag`）。非编辑时格子上唯一的按住手势就是长按 0.5 秒，**没人抢**，必触发；进编辑后 `onDrag` 挂上，拖动可用。
- **空白处新增**：VStack 上加 `.onLongPressGesture(minimumDuration: 0.5)`（长按空白进编辑），与格子长按并列。
- **格子点按改成 `.highPriorityGesture(TapGesture())`**：图标点按优先于父级 VStack 的点空白退出，编辑模式点图标不再悄悄退出编辑；非编辑模式点图标仍正常启动。
- **已知偏差（写清）**：同一根手指不能从「长按进编辑」无缝继续拖动——`onDrag` 是在进编辑那一刻才挂上的，正在进行的这次触摸它收不到。进编辑后松开手指，再长按一次即可拖动（和 iPhone 真实桌面第二次按住拖动一致）。这是 SwiftUI 手势挂载时机的限制，不是逻辑 bug。

### 改后流程

- 长按空白 0.5 秒 → 进编辑（图标抖动、左上 `+`、右上 `···` 出现）。
- 长按图标 0.5 秒 → 同样进编辑。
- 点空白处 → 退出编辑（`exitEditMode()`）；点 `···` → 完成 → 退出编辑。

---

## 7. 拖动丝滑（和 iPhone 真实桌面一样跟手）

只调动画/跟手参数，**功能逻辑一字未动**：同页排序、跨页、拖入拖出 Dock、拖第 5 个进 Dock 挤出最后一个，全部保持原样。

| 位置 | 原来 | 现在 | 为什么 |
|---|---|---|---|
| 图标抬起（`LCDesktopGridCell`） | scale 1.08、opacity 0.6、无阴影，变化无动画（瞬间跳变） | scale **1.15**、opacity **0.85**、阴影黑 0.3 / radius 12 / y 8，`.animation(.spring(response: 0.3, dampingFraction: 0.75), value: isDragged)` | 拖起的图标要「浮起来」：更大、带阴影、弹簧抬起/落下；原来只变暗、无阴影、无动画，看着像贴纸被抠掉 |
| Dock 图标抬起（`LCDesktopDockView`） | opacity 0.6，无缩放、无阴影、无动画 | scale **1.12**、opacity **0.85**、阴影黑 0.3 / radius 10 / y 6，spring(0.3, 0.75) | 同上，Dock 与网格一致 |
| 落位（`moveIcon` / `moveIconToPageEnd` / `dropIconOnDock`，`LCAppListView`） | 直接改 order，无任何动画包装——松手瞬间跳格 | 包进 `withAnimation(.spring(response: 0.35, dampingFraction: 0.8))` | 松手后图标**滑**到新位置、带回弹，而不是定格跳变 |
| 悬停目标格（`isDropTarget`） | opacity 直接变 0（虚线空位瞬间出现） | `.animation(.easeInOut(duration: 0.15), value: isDropTarget)` | 空位淡入淡出，不闪 |
| 边缘翻页（`LCDesktopDrag.beginEdgeFlip` + `flipPage`） | 0.7 秒定时器 + `withAnimation`（默认曲线） | 定时器 **0.5 秒** + `withAnimation(.spring(response: 0.35, dampingFraction: 0.85))` | 悬停边缘半秒即翻页（iPhone 约 0.5 秒），翻页是弹簧滑过去不是生切 |
| 抖动 | 旋转 ±1.2°、0.12s easeInOut repeatForever | **不变** | 已经和 iPhone 抖动一致 |

### 仍比 iPhone 差的一处（写清，不藏着）

iPhone 真实桌面是**拖动中下面图标就实时让位**（边拖边排）。本实现仍是系统 `onDrag` / `onDrop`：悬停时只显示虚线空位，真正换位发生在松手 `performDrop` 那一刻（只是现在落位有弹簧滑过去，不再是瞬间跳格）。要做到拖动中实时让位，需要把换位逻辑搬进 `dropEntered`（拖过哪个格子就实时改 order），那是**逻辑改动**，不是动画参数——本批按 MJ「只调动画跟手程度，不改拖动功能逻辑」没做，列为下一批可选。

---

## 8. 「虚拟手机桌面」总纲核对：哪些是真的，哪些还是假的

逐项核对（按代码路径核实，不是凭印象）：

| 功能 | 真 / 假 | 证据（代码位置） |
|---|---|---|
| 图标点开真的启动客 App | **真** | `desktopIconTapped` → `.app` → `launchDesktopApp` → `app.runApp()`（`LCAppListView.swift:1549` 起）；锁定的 App 先走 `LCUtils.authenticateUser()`，失败不启动并报错 |
| Dock 里的是真的 App，点 Dock 图标真的启动 | **真** | Dock 点按走同一条 `desktopIconTapped` → `launchDesktopApp` → `runApp()`；Dock 图标来自 `dockDisplayIcons`（已装 App 的 `LCDesktopIcon`，与网格里的是**同一个 App 的同一个 id**，不是占位副本）；启动后 `LCDesktopLaunchCountStore.recordLaunch` 计次，Dock 的「最常用」排序据此排 |
| Dock 顺序持久化，重启还在 | **真** | `LCDesktopDockStore` 持久化 `dockIDs`（App Group UserDefaults）；启动时 `refreshDock()` 读回；拖入拖出/移出都写回。**但**：Dock 内部 4 个图标之间的相互排序目前没有拖拽换位（Dock 图标只能拖出、不能在 Dock 内调换顺序），是已知缺口（见 §9） |
| Dock 里的 − 是移出 Dock 回网格，不是删 App | **真** | `removeIconFromDock`：`desktopDock.removeFromDock` + `desktopOrder.insert(…, at: .count)`（回网格末尾），不碰文件 |
| 系统图标（源/设置/插件）不许进 Dock | **真** | 三重防线：`addToDock` / `dropIconOnDock` 拒绝 `isSystemID`；`refreshDock` 启动时清掉旧存量 `sys:` id；`dockDisplayIcons` 只含 App 图标。系统图标点开走 `systemPage`（`LCSourcesView` / `LCTweaksView` / `LCSettingsView`，全屏 cover，Done + 左滑返回） |
| 壁纸真的能换 | **真** | `···` → 壁纸 → PHPicker 选图 → 直接应用（无编辑页，按 MJ 定）；存 App Group `SealBoxWallpaper/wallpaper.jpg`，重启还在；默认壁纸是随包内置的雨天自拍（`DefaultWallpaper.imageset`），恢复默认删掉自定义文件即回默认 |
| 主题真的能切 | **真** | `···` → 主题色 Picker（跟随系统 / 深色 / 浅色），写 App Group `LCDesktopTheme`，`preferredColorScheme(desktopTheme.colorScheme)` 立即生效；壁纸与主题分开存 |
| 搜索真的能搜到 | **真** | `···` → 搜索 → 悬浮搜索框，`filteredApps` 按显示名 + Bundle ID 过滤（`localizedCaseInsensitiveContains`）；搜到点开正常启动；搜索时拖动禁用（防排错顺序）、系统图标隐藏 |
| 删除真的删文件 | **真** | 网格 `−` → `deleteDesktopApp` → `LCAppModel.uninstallFiles(for:removeDataFolders:)`：删 bundle + 每个容器的 `Documents/Data/Application/<dataUUID>/` + 各容器钥匙串 + DataManager 注册表；删失败时桌面不动并报错；共享 App（`uiIsShared`）无 `−`、拒绝删除 |
| 拖动真的改顺序并存下来 | **真** | `desktopOrder.move/insert` 写持久化顺序；同页、跨页（边缘热区 28pt / 悬停 0.5 秒翻页）、拖入拖出 Dock、拖第 5 个进 Dock 挤出最后一个回网格末尾，均走同一套 order 存储；`syncDesktopOrder()` 启动时对齐 |
| 排序菜单 | **真** | `···` → 排序 Picker（上游 `AppSortType` 全部档位）；选「自定义」弹出上游自定义排序页（`customSortViewPresent`） |
| `+` 导入 | **真** | 编辑模式左上 `+` → `choosingIPA = true` → 现有文件选择导入流程（`LCAppListView` 的 `choosingIPA` / `importIpaFile` 链路） |
| 编辑模式 `+` / `···` / 点空白退出 | **真** | §6 已修；进编辑后 `+` 左上、`···` 右上、图标抖动带 `−`（IPA 图标）、Dock 图标带 `−`（移出） |

### 还是假的 / 半截的（逐项写清，不藏着）

1. **Live Activity（灵动岛/锁屏安装进度）——本批开始时是半截的，结束时已补上**：`LCContainerLiveActivityManager` 在安装/启动时确实 request，但本批开始时 Fork 里没有 Widget Extension target，岛上/锁屏上不会显示。**并行提交 `00cb44f`（Add SealBoxWidgetExtension）已加了扩展**：锁屏横幅 + 灵动岛展开/紧凑/最小三种形态，安装显示确定进度条、启动显示转圈、完成打勾。详见 `SEALBOX_LIVE_ACTIVITY.md`。剩余：未编译，发布时扩展须自己的 App ID + 描述文件（Team ID 仍是占位）。
2. **Dock 内 4 个图标不能相互调换顺序**：Dock 图标只能拖回网格再拖进来排，不能在 Dock 里直接拖动换位（`LCDesktopDockView` 没有 Dock 内 DropDelegate）。手动顺序标志位 `LCDesktopDockManuallyEdited` 已有，但 Dock 内排序功能没做。
3. **文件夹没做**：图标不能叠成文件夹（MJ 尚未定要不要做）。
4. **iOS 15 Tab Bar 残留**：`hideDesktopTabBar()` 用 iOS 16+ API，iOS 15 上 Tab Bar 可能残留（老缺口，未动）。
5. **桌面顺序与 `LCCustomSortOrder` 两套存储未统一**：拖动改的是 `LCDesktopOrderStore`，上游自定义排序另有一套存储；两者关系待排期统一。
6. **状态栏「信号默认满格」只是效果图画法**：代码里不自画假状态栏、不读真实信号，显示的是系统真实状态栏（按 MJ 定）。
7. **长按进编辑后，同一根手指不能继续拖动**（§6 末尾）：须松开再按一次。
8. **拖动中下面图标不实时让位**（§7 末尾）：换位发生在松手那一刻（有弹簧滑过去，不跳格）。
9. **`draggedID` 落在无落点区域**：`scenePhase` 变化时 `endDrag()` 已兜底，但拖出屏幕边缘无落点的残留状态仍是已知缺口，待真机验证。
10. **安装 Live Activity 挂起路径**：`installIpaFile` 中途 return 的个别路径可能不 finish/endNow（v1 报告遗留，待排期）。
11. **悬浮返回按钮的旋转跟随没做**（§5）：旋转后位置不自动跟随，可拖回。
12. **URL 安装入口未补回**：桌面重做时拆掉的旧入口之一，待排期。

---

## 9. 本批逐项核对清单（MJ 收尾清单）

| 项 | 结果 |
|---|---|
| 长按进编辑（空白处 / 图标） | ✅ 修了（§6）：空白处新增长按；图标 `onDrag` 只在编辑模式挂载，长按不再被吃 |
| `+` / `···` 出现 | ✅ 编辑模式左上 `+`、右上 `···`（原有逻辑，进编辑即出现；长按修好后可达） |
| 点空白退出 | ✅ 原有 `.onTapGesture` 保留；格子点按改高优先级后，编辑模式点图标不再误触发退出 |
| Dock 毛玻璃 | ✅ `.ultraThinMaterial` + 1pt 白描边 + 76pt 固定高度；无不透明底色（grep 验证） |
| Dock 固定 | ✅ `safeAreaInset(bottom)` + 忽略键盘安全区（未动） |
| 左滑返回（系统页） | ✅ 左边缘 24pt 起手、右滑 > 80pt、横向为主；Done 保留 |
| 进 App 回桌面 | ✅ 经典模式悬浮 `house.fill` 按钮（点按回桌面、可拖动）；多任务模式用窗口关闭；`dontInjectTweakLoader` 的 App 用原生 Home 手势 + 切换器划掉 + 点 SealBox |
| 拖动跟手 | ✅ 抬起 1.15/阴影/弹簧、落位弹簧 0.35/0.8、边缘翻页 0.5 秒/弹簧、悬停空位淡入；功能逻辑未动 |
| Dock 里是真 App、点开真启动 | ✅ 同一条 `launchDesktopApp` → `runApp()`；Dock 与网格同一 App 同一 id；顺序持久化；`−` 回网格；系统图标禁入 |

---

## 10. 改动清单（5 个文件，+292 / −33）

| 文件 | 改动 |
|---|---|
| `LiveContainerSwiftUI/Views/AppList/LCAppListView.swift` | body 根包 `GeometryReader`，内容顶边 `geometry.safeAreaInsets.top`；VStack 加空白处长按 0.5 秒进编辑；系统页 cover 加左边缘右滑返回（24pt 热区 / >80pt / 横向为主，Done 保留）；网格 `onDrag` 只在编辑模式挂载；`moveIcon` / `moveIconToPageEnd` / `dropIconOnDock` 包弹簧动画；`flipPage` 改弹簧曲线 |
| `LiveContainerSwiftUI/Views/AppList/LCDesktopDockView.swift` | Dock 加 1pt 白描边 + 76pt 固定最小高度（空条可见）；Dock 图标 `onDrag` 只在编辑模式挂载；Dock 图标抬起改 1.12 / 0.85 / 阴影 / 弹簧 |
| `LiveContainerSwiftUI/Views/AppList/LCDesktopGridCell.swift` | 抬起改 1.15 / 0.85 / 阴影 / 弹簧；悬停目标格淡入淡出；点按改 `.highPriorityGesture`（编辑模式点图标不再误触退出） |
| `LiveContainerSwiftUI/Views/AppList/LCDesktopDrag.swift` | 边缘翻页定时器 0.7 秒 → **0.5 秒** |
| `TweakLoader/UIKit+GuestHooks.m` | 新增悬浮返回按钮：经典模式客 App 内 52pt 半透明 `house.fill` 圆钮（可拖动），点按写 `selected=@"ui"` + LSApplicationWorkspace 打开自身 + `raise(SIGKILL)` 回桌面；`UIKitGuestHooksInit` 末尾 1 秒后安装（`!isLiveProcess` 才装）；`#include <signal.h>` |

**未动的**：Bundle ID / Scheme / 钥匙串 / App Group / SideStore / JIT / Seal 仓库——一律未动。

## 11. 验证

- 括号配平：5 个文件全部通过（自写检查器：先去字符串、再去 `//` 与 `/* */` 注释，再核对 `{[(`；第一版检查器因字符串里的 `//` 误报，已修正后重跑）。
- switch 全分支：改动涉及的 `switch icon`（`desktopIconTapped`，2 分支全覆盖）、`switch direction`（`flipPage`，未动逻辑）均穷尽，无缺 return。
- grep：Dock 文件里无不透明底色——`Color.white` 只出现在 1pt 描边（`opacity(0.25)`）与注释里，无 `Color.gray` 填充、无 `.fill(Color` 实心底。
- grep：网格与 Dock 的 `.onDrag` 只出现在 `isEditing` 分支内（各一处）；`onLongPressGesture(minimumDuration: 0.5)` 在 VStack（空白处）、格子、Dock 图标三处。
- **未编译**：本机 Linux 无 Xcode/Swift，**没有编译、没有真机验证**。须在 Mac / GitHub Actions（Xcode 26.2）先编改后版，重点真机验证：① 长按空白/图标进编辑；② 空 Dock 可见、毛玻璃透壁纸；③ 第一行图标不挡时间；④ 系统页左滑回桌面；⑤ 进客 App 后点悬浮按钮回桌面；⑥ 拖动抬起/落位/翻页手感；⑦ 悬浮按钮在客 App 里是否出现、是否挡操作、点按是否真的回桌面（注意：私有 API 调用在 Xcode 里须确认只是 warning）。另：TweakLoader 的改动只影响 `dontInjectTweakLoader == false` 的客 App（默认全部），改后须逐个客 App 抽查按钮是否出现。
