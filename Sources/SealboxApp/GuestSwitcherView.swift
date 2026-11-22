import SwiftUI

/// 0.2.44（问题 3）：后台客切换器——形状对齐 LiveContainer 上游
///（LCAppSwitcherView：卡片以 dataUUID 为键、removeCard／bringGuestToFront／
/// closeGuest／exitToDesktop），teardown 用 SealBox 进程内新逻辑
///（SBGuestSessionManager.closeGuestWithBundleID:，不照搬上游——上游自己
/// 写明未验证场景是否真死，LCAppSwitcherView.swift:235-236,916-918）。
/// 数据源是 activeSessions() 只读快照（bundleID／containerUUID／
/// lastActiveAt）；displayName 由 SBStore 查；绝不画假截图、不编造数据。
/// 点卡恢复走同一条 resumeGuest（与桌面图标点按同一条路）。
/// 入口：桌面“切换器”按钮／客内横杠长按，都发 SBGuestSwitcherRequested
/// 通知，VMRootView 接到即弹本页。
struct GuestSwitcherView: View {
    @EnvironmentObject private var vm: VMState
    @EnvironmentObject private var coordinator: SBAppCoordinator
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SBStore.shared
    @State private var sessions: [SwitcherSession] = []

    /// 快照一行：containerUUID 即卡片的键（上游 dataUUID 的等价物）。
    private struct SwitcherSession: Identifiable {
        let bundleID: String
        let containerUUID: String
        let lastActiveAt: Date?
        var id: String { containerUUID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    VStack(spacing: 12) {
                        Text("没有正在运行的应用")
                            .font(.headline)
                        Text("点开一个应用后，它会在这里出现")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(sessions) { session in
                            card(for: session)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("切换器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("回到桌面") {
                        // 只关切换器浮层，不动任何客会话（上游 exitToDesktop 同款）。
                        dismiss()
                    }
                }
                if !sessions.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("全部结束") {
                            closeAll()
                        }
                    }
                }
            }
        }
        .onAppear { refresh() }
    }

    private func card(for session: SwitcherSession) -> some View {
        let record = store.installedApps.first {
            $0.bundleID == session.bundleID && $0.containerUUID == session.containerUUID
        }
        return HStack(spacing: 12) {
            if let record {
                InstalledAppIconView(app: record, size: 48)
            } else {
                AppIconView(name: session.bundleID, size: 48)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(record.map { SBStore.shared.displayName(for: $0) } ?? session.bundleID)
                    .font(.headline)
                    .lineLimit(1)
                if let lastActiveAt = session.lastActiveAt {
                    Text("上次活跃 \(VMTime.dateTimeString(for: lastActiveAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("正在运行")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                closeGuest(session)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // 点卡恢复：与桌面图标点按同一条 resumeGuest 路。
            bringGuestToFront(session)
        }
    }

    /// 上游 bringGuestToFront 同款：恢复该客到前台，关切换器。
    private func bringGuestToFront(_ session: SwitcherSession) {
        if SBGuestSessionManager.shared().resumeGuest(withBundleID: session.bundleID) != nil {
            dismiss()
        } else {
            // 恢复失败（会话已不在）：刷新列表，不弹错（记录可能已被删）。
            refresh()
        }
    }

    /// 上游 removeCard＋closeGuest 同款：关一客，刷新列表；最后一张关掉
    /// 即直接回桌面（不再留空切换器）。
    private func closeGuest(_ session: SwitcherSession) {
        SBGuestSessionManager.shared().closeGuest(withBundleID: session.bundleID)
        refresh()
        if sessions.isEmpty {
            dismiss()
        }
    }

    /// 全部结束：逐个关（closeGuest 是同步的，顺序即逐个），关完回桌面。
    private func closeAll() {
        for session in sessions {
            SBGuestSessionManager.shared().closeGuest(withBundleID: session.bundleID)
        }
        refresh()
        dismiss()
    }

    private func refresh() {
        let raw = SBGuestSessionManager.shared().activeSessions() as? [[AnyHashable: Any]] ?? []
        sessions = raw.compactMap { dict in
            guard let bundleID = dict["bundleID"] as? String,
                  let containerUUID = dict["containerUUID"] as? String else { return nil }
            return SwitcherSession(
                bundleID: bundleID,
                containerUUID: containerUUID,
                lastActiveAt: dict["lastActiveAt"] as? Date)
        }
    }
}
