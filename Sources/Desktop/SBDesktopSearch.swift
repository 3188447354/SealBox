// 桌面搜索：按名字 / Bundle ID 过滤，结果列表逻辑。
import SwiftUI

/// 搜索逻辑（纯函数，便于单测与 SBDesktopView 复用）。
enum SBDesktopSearch {
    /// 搜名字或 Bundle ID，不区分大小写；空查询返回全部。
    static func filter(apps: [SBInstalledApp], query: String) -> [SBInstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return apps }
        let lower = trimmed.lowercased()
        return apps.filter { app in
            app.displayName.lowercased().contains(lower) || app.bundleID.lowercased().contains(lower)
        }
    }
}

/// 悬浮搜索结果列表：有结果列出应用，无结果显示「没有找到相关应用」。
struct SBDesktopSearchResultsView: View {
    let results: [SBInstalledApp]
    let query: String
    var onSelect: ((SBInstalledApp) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("没有找到相关应用")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(results, id: \.bundleID) { app in
                    Button(action: { onSelect?(app) }) {
                        HStack(spacing: 12) {
                            SBDesktopCell(app: app, iconSize: 44, onTap: { onSelect?(app) })
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.displayName)
                                    .font(.system(size: 15))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text(app.bundleID)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
    }
}
