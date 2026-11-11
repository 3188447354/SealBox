# SealBox 灵动岛补齐报告

分支：`SealBox`（基线：首页重做提交 `6b9995b`）
本次提交：见 `git log`（灵动岛 Widget Extension + 本报告）
日期：2026-11-08

**未编译**：本机 Linux，无 Xcode，全部只做了静态检查，须 Mac / GitHub Actions（Xcode 26.2）构建验证（见“验证”与“CI 清单”）。

之前的状态：App 侧 Live Activity 的 request / update / end 已经写好
（`LCContainerLiveActivityManager`），`Info.plist` 已加
`NSSupportsLiveActivities = YES`，但没有 Widget Extension 提供
`ActivityConfiguration`，所以岛上什么都显示不出来。现在补齐了。

---

## 1. 新 target：SealBoxWidgetExtension

| 项目 | 值 |
|---|---|
| Target 名 | `SealBoxWidgetExtension` |
| 产品 | `SealBoxWidgetExtension.appex`（app-extension，`com.apple.product-type.app-extension`） |
| Bundle ID | `com.mjorb.sealbox.WidgetExtension`（Release；Debug 按全仓惯例带 Team 后缀，见下） |
| 部署目标 | iOS 16.1（Live Activity 最低要求；主 App 仍是 15.0，扩展在 iOS 15 设备上不加载） |
| 目录 | `SealBoxWidgetExtension/`（文件系统同步组，文件放进去自动编进 target） |
| 签名 | 沿用全仓占位方式：`DEVELOPMENT_TEAM = AAAAA11111`（占位，未编真的）；`CODE_SIGN_STYLE = Automatic` |
| Entitlements | 无。Live Activity 不需要新 entitlement；扩展不读 App Group，不新建组、不新建 entitlements 文件 |

### Bundle ID 怎么拼

`xcconfigs/WidgetExtension.xcconfig`（新增）：

```xcconfig
#include "Global.xcconfig"
PRODUCT_BUNDLE_IDENTIFIER = $(LIVECONTAINER_BUNDLE_IDENTIFIER).WidgetExtension
```

`LIVECONTAINER_BUNDLE_IDENTIFIER` 在 `Global.xcconfig` 里是
`com.mjorb.sealbox$(DEVELOPMENT_TEAM_SUFFIX)`，Debug 下
`DEVELOPMENT_TEAM_SUFFIX = .AAAAA11111`，Release 下为空——和
ShareExtension / LiveProcess 的拼法完全一致。所以：

- Release：`com.mjorb.sealbox.WidgetExtension`
- Debug：`com.mjorb.sealbox.AAAAA11111.WidgetExtension`

### 发版前要在开发者账号里建的 App ID

| App ID（Bundle ID） | 描述文件 |
|---|---|
| `com.mjorb.sealbox.WidgetExtension` | Widget Extension 一份（主 App、LiveProcess、两个扩展的各一份之外，再加这一份） |

Team ID 填真的之后，Debug 的后缀问题随全仓惯例走（与现有扩展一致）。

### 扩展怎么被编进包、怎么被打包脚本带走

- 主 App target 的 `Embed Foundation Extensions` 阶段（`dstSubfolderSpec = 13`，即 `PlugIns/`）已加入 `SealBoxWidgetExtension.appex` 的 build file；主 App target 对新 target 有 `PBXTargetDependency`，所以编主 App 时自动编扩展、自动嵌进 `SealBox.app/PlugIns/`。
- Scheme 不用改：`SealBox.xcscheme` 的 `BuildAction` 是 `buildImplicitDependencies = YES`，依赖 target 会随主 App 一起编。
- `.github/build_github.sh` 不用改：它只对 SideStore 的 `LiveWidgetExtension.appex` 做移动/重签，没有枚举全部 `.appex` 的逻辑；新的扩展随 `Payload/` 整个 zip 进 `SealBox.ipa` 与 `SealBox+SideStore.ipa`。

---

## 2. Attributes 怎么共享：两边各一份逐字相同

Apple 文档的共享方法：Attributes 定义文件同时是 app target 和 widget
extension target 的成员。本次按这个方法做，没有新建共享 framework
（把整个 LiveContainerSwiftUI 框架链进扩展进程太重，且无必要）。

- App 侧：`LiveContainerSwiftUI/LiveActivity/LCContainerLiveActivityAttributes.swift`
  （新文件；struct 从 `LCContainerLiveActivity.swift` 原样搬出，
  `LCContainerLiveActivityManager` 留在原文件，同 module 直接引用）。
- 扩展侧：`SealBoxWidgetExtension/LCContainerLiveActivityAttributes.swift`
  （新文件；用 `cp` 从 app 侧复制，保证字节相同）。

两份文件头都有 `KEEP IN SYNC` 说明。**验证是程序 diff，不是肉眼**：

```
cmp LiveContainerSwiftUI/LiveActivity/LCContainerLiveActivityAttributes.swift \
    SealBoxWidgetExtension/LCContainerLiveActivityAttributes.swift
→ IDENTICAL
```

改字段时两边一起改，改完重新跑上面这条命令。系统按 Attributes 的
类型名 + Codable 结构把活动匹配到 widget，两边对不上岛就出不来。

Attributes 定义（两边相同）：

- `appName: String`（客 App 名）、`kind: Kind`（`.install` / `.launching`）
- `ContentState`：`progress: Double`（0...1）、`statusText: String`、
  `isFinished: Bool`

---

## 3. 岛上三种形态 + 锁屏各显示什么

实现在 `SealBoxWidgetExtension/SealBoxLiveActivityWidget.swift`
（`ActivityConfiguration(for: LCContainerLiveActivityAttributes.self)`），
入口在 `SealBoxWidgetBundle.swift`（`@main WidgetBundle`，只含这一个
Live Activity widget，没有主屏幕小组件）。

| 位置 | 显示内容 |
|---|---|
| 锁屏横幅 | App 名（粗体）+ 状态文案 + 进度条 + 百分比；完成态显示绿色 ✓ + 完成文案 + 满格进度条 |
| 灵动岛展开 leading | App 名 |
| 灵动岛展开 trailing | 百分比（安装）/ 转圈（启动中）/ 绿色 ✓（完成） |
| 灵动岛展开 center | 状态文案 |
| 灵动岛展开 bottom | 进度条（安装/完成）或转圈（启动中） |
| 灵动岛收起 compactLeading | 百分比 / 转圈 / ✓ |
| 灵动岛收起 compactTrailing | 箱子图标（`shippingbox.fill`） |
| 灵动岛 minimal | 圆形进度环 / ✓ |

按 kind 区分（manager 侧的行为不动）：

- **安装（`.install`）**：确定性进度条 + 百分比，`updateProgress` 推着走。
- **启动中（`.launching`）**：没有有意义的进度（manager 只报 progress 0），
  显示不定转圈，不画假进度条。
- **完成态（`isFinished`，progress 1.0）**：✓ + 完成文案；manager 的
  8 秒保留逻辑不动（先 update 到完成态、停 ~8 秒再 end，立刻 end 的话
  系统会马上把活动从岛上撤下，用户看不到完成态）。

所有文案（App 名、状态文案）都由 app 侧传过来、已经本地化过，扩展
bundle 里没有自己的 Localizable 字符串，不在这里再本地化。

**不做推送更新**：Live Activity 的内容更新只来自 app 进程的
ActivityKit 调用。远程推送更新要接 Apple Push Notification 服务，
本次不做。

---

## 4. 客 App 自己的 Live Activity 做不了

客 App 从未安装在系统里，系统只认容器这一个 Bundle ID
（`com.mjorb.sealbox`）。只有容器自己的活动能发、能显示；客 App
自己的 Live Activity 没有实现途径，本次没有试图做。

---

## 5. Info.plist / entitlements 核对

- 扩展的 `SealBoxWidgetExtension/Info.plist`（新增）：`NSExtension`
  只含 `NSExtensionPointIdentifier = com.apple.widgetkit-extension`；
  其余键（DisplayName / Executable / Identifier / Name / PackageType
  `XPC!` / 版本）照 ShareExtension 的 Info.plist 模板。
- 主 App 的 `LiveContainer/Info.plist` 不用动（`NSSupportsLiveActivities`
  早就加了）。
- 没有新增 entitlements 文件；现有三份 entitlements 不用动。

---

## 6. 验证（静态，本机 Linux，无 Xcode）

1. Attributes 两边程序 diff：`cmp` → **IDENTICAL**（见 §2）。
2. 括号配平：5 个相关 Swift 文件（两个 Attributes 副本、
   `SealBoxWidgetBundle.swift`、`SealBoxLiveActivityWidget.swift`、
   `LCContainerLiveActivity.swift`）`{}`/`()`/`[]` 全部平衡。
3. `LCContainerLiveActivityAttributes` 的 struct 定义全仓恰好 2 处
   （app 侧、扩展侧各一处）；`TODO(WidgetExtension)` 全仓 0 条。
4. pbxproj 程序核对：新 target 在 `PBXNativeTarget` 与项目 targets
   列表里；`.appex` 在 `Embed Foundation Extensions` 的 files 里；
   主 App target 的 dependencies 里有新 target 的 dependency；
   两个新 XCBuildConfiguration 都引用 `WidgetExtension.xcconfig`、
   `IPHONEOS_DEPLOYMENT_TARGET = 16.1`（2 处）；无 widget 的
   entitlements 引用；`{}`/`()` 全仓平衡；对象定义 ID 无重复
   （197 个定义）。
5. `SealBoxWidgetExtension/Info.plist` 用 plistlib 读过，合法。

### 须 GitHub Actions / 真机验证的事（CI 清单）

- archive 能不能找到新 target：`xcodebuild archive -scheme SealBox`
  是否编出 `SealBoxWidgetExtension.appex` 并嵌进
  `SealBox.app/PlugIns/`。
- 岛上是否显示：装一个 IPA 看安装进度条、启动中转圈、完成态 ✓
  （8 秒保留）；锁屏横幅是否同样显示。
- 两个 IPA（`SealBox.ipa`、`SealBox+SideStore.ipa`）里是否都有
  该 `.appex`。
- iOS 15 设备上主 App 是否仍正常启动（扩展不加载，不应影响主 App）。

---

## 7. 改动文件清单

- 新增 `SealBoxWidgetExtension/`：
  - `LCContainerLiveActivityAttributes.swift`（Attributes 副本，与 app 侧字节相同）
  - `SealBoxWidgetBundle.swift`（`@main WidgetBundle`）
  - `SealBoxLiveActivityWidget.swift`（`ActivityConfiguration`：锁屏 + 岛三种形态）
  - `Info.plist`（`com.apple.widgetkit-extension`）
- 新增 `xcconfigs/WidgetExtension.xcconfig`（Bundle ID 拼法）。
- 新增 `LiveContainerSwiftUI/LiveActivity/LCContainerLiveActivityAttributes.swift`
  （Attributes 从 manager 文件搬出）。
- 改 `LiveContainerSwiftUI/LiveActivity/LCContainerLiveActivity.swift`
  （删 Attributes 定义、删 `TODO(WidgetExtension)`、更新头注释；manager 逻辑一行未动）。
- 改 `LiveContainer.xcodeproj/project.pbxproj`（新 target + 三个 build phase +
  同步组 + 产品引用 + Embed 阶段 + target 依赖 + Debug/Release 配置 + 项目
  targets 列表；共 12 个新对象 ID，全部程序生成并验重）。
- 本报告 `SEALBOX_LIVE_ACTIVITY.md`。

### 附：版本不一致（顺手发现，未动）

主 App target 的 `MARKETING_VERSION` 在 pbxproj 里是 `3.3.55`，
ShareExtension 是 `3.7.11`，而应用实际版本是 3.8.11。新扩展用了
3.8.11（`CURRENT_PROJECT_VERSION` 与 `MARKETING_VERSION` 均为
3.8.11）。发版前统一版本号时顺手把这三处对齐，不在本任务里改。
