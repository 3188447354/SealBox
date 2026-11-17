# Sealbox

Sealbox 是一个新产品：打开就是一个手机系统 UI，只做 IPA 导入，桌面点图标启动客 App。

它不是模拟器、不是虚拟机。客 App 在宿主进程内运行（Mach-O 改造成 dylib 后 `dlopen` 跳入口），
不走系统安装、不占 App ID。容器做法借鉴 LiveContainer 的思路，**代码全部从零写，不含
LiveContainer 的任何源文件**。

## 能做什么

- 导入 IPA（应用内文件选择器），解压、打补丁、重签后落到桌面
- 桌面点图标启动客 App；客 App 内上滑横杠回桌面
- 桌面编辑：长按抖动、拖动换位、Dock、搜索
- 设置：证书管理、JIT 状态、存储用量、关于

## 诚实边界（关于页同样写明，不得宣称不存在）

- 客 App 的 entitlement 不生效，只用宿主那一份
- 客 App 容器之间不隔离：一个客 App 能读其他客 App 的数据
- 权限全局共享；远程推送不工作；App Extensions（小组件、分享扩展等）不支持
- 32 位应用须 JIT；依赖宿主没有的能力的客 App 功能不可用
- 宿主须由开发证书签名；iOS 26+ 上无证书连启动入口都进不去；免费证书 7 天过期需续签
- 不承诺“所有 IPA 都能跑”；跑不起来的客 App 在详情页记失败原因

## 构建

CI（GitHub Actions，Xcode 26.2）构建 Release 并产出未签名 IPA（`SealBox.ipa`），
再由 Seal / SideStore / AltStore 签名安装。本地构建：

```sh
xcodebuild archive -archivePath archive -scheme SealBox \
  -project SealBox.xcodeproj -sdk iphoneos -arch arm64 -configuration Release \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
sh .github/build_github.sh   # 从 archive 导出 SealBox.ipa
```

构建前 CI 会 clone 两个第三方依赖（不进仓库）：
`OpenSSL`（krzyzanowskim/OpenSSL，ZSign 的加密库）与 `litehook`（dyld Hook 底层，MIT）。

## 许可证

MIT License。见 `LICENSE`。
