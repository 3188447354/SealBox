# 虚拟机 (PhoneVM shell in the SealBox repo)

iPhone 手机虚拟机的前端 UI 壳子：打开就是一台 iPhone 主屏幕的样子。

- 内置 3 个应用图标：设置、软件源、插件（纯展示）
- 底部 Dock：电话、Safari、信息、音乐（纯展示）
- **零功能**：点任何图标都什么都不发生，不跳转、不弹层、不联网、不存数据

## 身份

- Bundle ID：`com.mjorb.sealbox`（与 SealBox 0.1.x 相同）
- App Group：`group.com.mjorb.sealbox`（entitlements.xml 未动）
- 版本：0.1.2 / build 3
- 最低 iOS 15.0

## 历史

- 0.1.0–0.1.1：SealBox 容器应用（IPA 导入、重签、桌面启动）。
- 0.1.2：SealBox 代码全清，改成虚拟机前端 UI 壳子；仓库、Bundle ID、App Group、CI 流程不变。

## 构建

GitHub Actions（`.github/workflows/build.yml`）：无签名 Archive → runner 内自签证书以 `codesign` 命令行签名并嵌 entitlements → 验签名槽 → 打 IPA。
