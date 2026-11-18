import SwiftUI

// MARK: - 启动诊断日志（0.2.4）

/// 设置页“启动诊断日志”区：上次启动是否崩了 + 查看全文（复制/分享）。
/// 全部内容取自本机真实日志文件，没有日志就显示“暂无日志”，不编数据。
struct StartupDiagLogSection: View {
    @State private var showingLog = false
    @State private var hasCrashedLog = false
    @State private var logSummary = "暂无日志"

    var body: some View {
        Section {
            HStack {
                Text("上次启动")
                Spacer()
                Text(logSummary)
                    .foregroundStyle(hasCrashedLog ? .red : .secondary)
            }
            Button("查看启动日志") { showingLog = true }
        } header: {
            Text("启动诊断日志")
        } footer: {
            Text("每次启动的步骤都实时写盘；上次启动没完成就崩了会留下来，下次启动能看到死在哪一步。")
        }
        .sheet(isPresented: $showingLog) {
            StartupDiagLogView()
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        hasCrashedLog = SBDiagLog.hasCrashedLog
        if hasCrashedLog {
            logSummary = "崩溃了，日志已保留"
        } else if SBDiagLog.latestText() != nil {
            logSummary = "正常"
        } else {
            logSummary = "暂无日志"
        }
    }
}

/// 启动日志全文页：等宽字、可选文本、复制与系统分享。
private struct StartupDiagLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logText = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(logText.isEmpty ? "暂无日志" : logText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("启动日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "已复制" : "复制") {
                        UIPasteboard.general.string = logText
                        copied = true
                    }
                    .disabled(logText.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: logText.isEmpty ? "暂无日志" : logText) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .onAppear {
                logText = SBDiagLog.latestText() ?? ""
            }
        }
    }
}
