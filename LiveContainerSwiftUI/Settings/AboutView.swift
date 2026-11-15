//
//  AboutView.swift
//  LiveContainerSwiftUI
//
//  SealBox 0.0.3 rebuild — about page (implementation #2).
//
//  The honest-boundaries page. Everything here is a limitation of the
//  LiveContainer architecture (research §2 section 0, §3.3, §5.4), not
//  a bug list: entitlements do not apply, guest containers are not
//  isolated, there is no push, no extensions, permissions are global,
//  and guest widgets cannot exist. None of it is softened, and the
//  compatibility line promises only what the upstream list promises:
//  apps not on the list will probably run; if one does not, file an
//  issue. "All IPAs run" is never promised.
//
//  SealBox is a fork of LiveContainer under AGPL-3.0: distributing the
//  IPA requires offering the complete corresponding source under the
//  same licence. It cannot be distributed as a closed-source product,
//  and it cannot go on the App Store (review guideline 2.5.2).

import Foundation
import SwiftUI

struct AboutView: View {
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "v\(short)（\(build)）"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SealBox")
                        .font(.largeTitle.bold())
                    Text(versionText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("在应用内启动 IPA 的启动器，不是模拟器，也不是虚拟机。客 App 在宿主进程内以动态库方式加载运行，从不经过系统安装。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                boundarySection(
                    title: "诚实边界",
                    rows: [
                        ("客 App 的权限声明不生效", "客 App 只能用宿主已有的权限声明。需要推送、App Attest、Associated Domains、个人 VPN、Apple Pay、钱包、CarPlay、Siri 等能力的应用，对应功能不可用或降级。"),
                        ("容器之间不隔离", "一个客 App 能读到其他客 App 的数据。钥匙串只有 128 组随机分配的半隔离，不是系统级隔离。不要把 SealBox 当作沙盒，也不要在里面登录你不信任的应用。"),
                        ("没有远程推送", "客 App 收不到系统推送；本地通知也可能有问题。"),
                        ("没有扩展", "客 App 的小组件、分享扩展、键盘、通知扩展都做不了——系统只认宿主一个 Bundle ID。"),
                        ("权限全局共享", "相机、相册、麦克风、定位等权限一旦授予宿主，所有客 App 共享；拒绝则全部拒绝。无法按客 App 单独授权。"),
                        ("不能上 App Store", "只能走侧载安装（AltStore / SideStore / Seal 签名）。"),
                        ("证书会过期", "宿主与客 App 的签名同过期。免费 Apple ID 证书 7 天过期，需定期续签；证书过期后客 App 无法启动。"),
                    ]
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("兼容性")
                        .font(.headline)
                    Text("不在列表里的 App 大概率能跑，跑不起来再提 issue。加密的 App Store IPA 无法安装，32 位应用需要 JIT，依赖宿主没有的能力的应用无法正常使用对应功能。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("开源协议")
                        .font(.headline)
                    Text("SealBox 基于 LiveContainer，遵循 AGPL-3.0 开源协议。分发 IPA 时须同时提供完整对应源码，修改同样以 AGPL-3.0 开源。")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Button("查看源码：github.com/3188447354/SealBox") {
                        if let url = URL(string: "https://github.com/3188447354/SealBox") {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.body)
                }
            }
            .padding(20)
        }
        .navigationTitle("关于 SealBox")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func boundarySection(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.0)
                        .font(.subheadline.bold())
                    Text(row.1)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
