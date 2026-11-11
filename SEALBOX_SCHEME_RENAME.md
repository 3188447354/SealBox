# SealBox 产物改名报告（scheme → SealBox）

分支：`SealBox`（基线：改名提交 `57b149e`）
本次提交：见 `git log`（scheme 改名 + 本报告）
日期：2026-11-08

MJ 定：CI 产物名叫 SealBox，不是 `LiveContainer.ipa`。

**未编译**：本机 Linux，无 Xcode，全部只做了静态检查，须 GitHub Actions（Xcode 26.2）构建验证。

---

## 1. 先核实：产物名到底由谁决定（结论：只改 scheme 不够）

核实结果——产物名分三层，各由不同的东西决定：

| 产物名 | 由谁决定 | 只改 scheme 会怎样 |
|---|---|---|
| IPA 文件名 `SealBox.ipa` | `build_github.sh` 里的 `"$scheme.ipa"`，scheme 来自 `build.yml` 的 `env.scheme` | 会变成 `SealBox.ipa`，这层够了 |
| .app 包名 `SealBox.app` | 主 target 的 `PRODUCT_NAME`（pbxproj 里 Debug/Release 各一行，原值 `LiveContainer`） | 仍是 `LiveContainer.app`；且脚本里 `Payload/LiveContainer.app` 写死了 45 处，不改 PRODUCT_NAME 脚本还能跑，但包里装的还是旧名 .app |
| 可执行文件名 | `LiveContainer/Info.plist` 的 `CFBundleExecutable`（硬编码字符串，原值 `LiveContainer`，不是 `$(EXECUTABLE_NAME)`） | 若只改 PRODUCT_NAME、不改它，编出来的可执行文件叫 SealBox，plist 却说可执行文件叫 LiveContainer，iOS 启动时找不到可执行文件、App 打不开。所以 PRODUCT_NAME 和 CFBundleExecutable 必须一起改 |

所以本次三处一起改：scheme、PRODUCT_NAME、CFBundleExecutable。

还有一处改名提交漏掉的：pbxproj 里主 target 两个配置都有 `INFOPLIST_KEY_CFBundleDisplayName = LiveContainer`。`INFOPLIST_KEY_*` 是构建期写进 Info.plist 的覆盖值，优先级高于 Info.plist 文件本身——也就是说，虽然 `LiveContainer/Info.plist` 里的显示名已经改成 SealBox，编出来的 App 在主屏幕上仍会显示 LiveContainer。本次已同步改成 SealBox。

入口符号 `LiveContainerMainC`（`LiveContainer/main.c:9` 定义，Release 配置 `OTHER_LDFLAGS -e _LiveContainerMainC` 引用）：只是 C 函数名，与可执行文件名无关，不动。

---

## 2. 改了哪些文件（旧值 → 新值）

- `LiveContainer.xcodeproj/xcshareddata/xcschemes/LiveContainer.xcscheme` → `SealBox.xcscheme`（`git mv` 改名）：里面 3 处 `BuildableName = "LiveContainer.app"` → `BuildableName = "SealBox.app"`。`BlueprintName = "LiveContainer"` 不动——那是内部 target 名，按“先别动”保留。
- `.github/workflows/build.yml`：`scheme: LiveContainer` → `scheme: SealBox`；步骤名 `Upload LiveContainer+SideStore` → `Upload SealBox+SideStore`。其余 `${{ env.scheme }}.ipa` / `${{ env.scheme }}+SideStore.ipa` 是变量引用，自动跟随。
- `LiveContainer.xcodeproj/project.pbxproj`（主 target 两个配置，Debug/Release 各一行）：
  - `PRODUCT_NAME = LiveContainer` → `PRODUCT_NAME = SealBox`（×2，全仓恰好 2 处，都是主 target）
  - `INFOPLIST_KEY_CFBundleDisplayName = LiveContainer` → `INFOPLIST_KEY_CFBundleDisplayName = SealBox`（×2，同两个配置）
- `LiveContainer/Info.plist`：`CFBundleExecutable` 的 `LiveContainer` → `SealBox`。
- `.github/build_github.sh`：
  - `Payload/LiveContainer.app` → `Payload/SealBox.app`（×45，全部）
  - 改名提交漏掉的旧标识（.sh 文件不在上次 grep 范围内），同文件顺手修掉，见 §3。
- `.github/update_json.py`（nightly 更新脚本，按产物文件名在 release 里找 asset）：
  - `f"LiveContainer.ipa"` → `f"SealBox.ipa"`（×2，第 79、180 行）
  - `f"LiveContainer+SideStore.ipa"` → `f"SealBox+SideStore.ipa"`（×1，第 261 行）
  - 另有 `news_entry` 里的 `"appID": "com.kdt.livecontainer"` → `"com.mjorb.sealbox"`（×2，第 116、305 行；news 的 appID 须与新 Bundle ID 一致，否则 AltStore 认不出这条 news 属于哪个 App）
- `LiveContainer/LCBootstrap.m`：注释 `// traverse back to LiveContainer.app` → `// traverse back to SealBox.app`（仅注释，路径是 `stringByDeletingLastPathComponent` 动态算的，与名字无关）。

### 没改的东西

- 内部 target 名、文件夹名、文件名里的 LiveContainer 不改；`BlueprintName`、`CFBundleExecutable` 之外的变量名、类名、入口符号 `LiveContainerMainC` 不改。
- Team ID 仍是占位 `AAAAA11111`；Bundle ID 不动，已经是 `com.mjorb.sealbox`。
- SideStore / JIT 不动。

---

## 3. 顺手修掉的改名残留（在 build_github.sh 里，上次改名漏了）

上次改名 grep 只覆盖了 plist/xcconfig/entitlements 和 swift/m，`.sh` 没查。这次在同一文件里发现并修掉：

| 旧值 | 新值 | 说明 |
|---|---|---|
| `com.kdt.livecontainer.sidestoreurlscheme` | `com.mjorb.sealbox.sidestoreurlscheme` | 写进成品 Info.plist 的 URL 类型名 |
| `com.kdt.livecontainer.sidestorebackupurlscheme` | `com.mjorb.sealbox.sidestorebackupurlscheme` | 同上 |
| `sidestore-com.kdt.livecontainer` | `sidestore-com.mjorb.sealbox` | 写进成品 Info.plist 的备用 URL scheme |
| `com.kdt.livecontainer.LiveWidget` | `com.mjorb.sealbox.LiveWidget` | 拷入的 AltWidgetExtension.appex 上改的 Bundle ID |

只改标识，不改 SideStore 行为。以下两处有意保留、没动：

- `ALTAppGroups` 的 `group.com.SideStore.SideStore`：那是 AltStore 生态的共享组，改名提交定好 SideStore 先不改，这里不动。
- `sidestore` 这个 scheme 字符串本身：SideStore 自己的 scheme，不动。
- 脚本里 `wget https://github.com/LiveContainer/dylibify/...` 与 `.../SideStore/releases/download/nightly/SideStore.ipa`：下载的上游工具，不动。

另：脚本第 72 行左右 `find payloadlc/Payload -type d -name "_CodeSignature" ...` 里的 `payloadlc` 是上游就有的笔误（应为 `Payload`），脚本无 `set -e`，这行报错也不中断。本次不动，记在这里。

---

## 4. 验证

本机 Linux，无 Xcode，**未编译**。以下全部是静态验证，2026-11-08 跑过：

1. 全仓 grep（0 条为通过）：
   - `grep -rn "LiveContainer\.ipa" .github/workflows/ .github/*.sh .github/*.py` → **0 条**
   - `grep -rn "scheme: LiveContainer" .github/` → **0 条**
   - `grep -rn "Payload/LiveContainer\.app" .github/` → **0 条**
   - `grep -rn "com\.kdt" .github/workflows/ .github/*.sh .github/*.py` → **0 条**
   - `PRODUCT_NAME = LiveContainer;` 全仓 → **0 条**；`INFOPLIST_KEY_CFBundleDisplayName = LiveContainer;` → **0 条**
   - 新值确认：`PRODUCT_NAME = SealBox` 在 pbxproj 1620、1667 行；`INFOPLIST_KEY_CFBundleDisplayName = SealBox` 在 1605、1649 行；`scheme: SealBox` 在 build.yml 第 18 行；update_json.py 第 79、180、261 行已是 SealBox 产物名。
2. 格式检查：`SealBox.xcscheme` XML 闭合 OK；`LiveContainer/Info.plist` plist 合法（`CFBundleExecutable = SealBox`、`CFBundleDisplayName = SealBox`、`CFBundleName = SealBox`）；pbxproj `{`/`}` 各 249、`(`/`)` 各 273，配平；`build_github.sh` bash 语法 OK；`update_json.py` Python 语法 OK；`build.yml` YAML 合法。
3. scheme 内引用一致：`BuildableName = "SealBox.app"` ×3；`BlueprintName = "LiveContainer"` ×3（target 名保留，有意）。

### 残留的 "LiveContainer.ipa"（有意保留，逐条说明）

只剩三处，都是历史数据文件里的上游旧版本下载地址，不是构建产物：

- `.github/apps.json`：上游 3.0.0–3.6.1 各版本的 `downloadURL`（指向 `github.com/LiveContainer/LiveContainer/releases/download/...`）
- `.github/apps_nightly.json`：nightly 的 `downloadURL`
- `.github/apps_ss_lc.json`：3.6.1 的 `downloadURL`

这些是 AltStore 源的历史条目，`update_json.py` 跑起来会在前面插入新版本条目；是否整体换源、改写历史条目，等 MJ 定，不在这次改。

另：`update_json.py` 里发版 news 的文案（`Update of LiveContainer just got released!`、指向 `github.com/LiveContainer/LiveContainer` 的 release/commit 链接）也没动——文案与仓库地址等 SealBox 仓库定下来再改。

### 产物名现在是什么

CI 编完应出两个产物（build.yml 的 `env.scheme` 已是 SealBox，artifact 名随之变）：

- `SealBox.ipa`（包里是 `Payload/SealBox.app`，可执行文件 `SealBox`，显示名 SealBox）
- `SealBox+SideStore.ipa`

---

## 5. 待验证 / 待定

1. **须 GitHub Actions 验证**：`xcodebuild archive -scheme SealBox ...` 能否找到新 scheme、PRODUCT_NAME 改名后 archive 产物是不是 `SealBox.app`、build_github.sh 全程是否跑通、IPA 里可执行文件与 plist 是否一致。
2. Scheme 改名后，`xcodebuild -list` 应列出 SealBox；本地 Xcode 打开工程时 scheme 下拉应显示 SealBox。
3. `update_json.py` 的 news 文案与上游仓库链接、`.github/apps*.json` 的历史条目，等 SealBox 仓库与发版源定下来再统一改。
