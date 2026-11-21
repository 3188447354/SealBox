import SwiftUI

// MARK: - 启动诊断日志（0.2.4；0.2.31 改文件夹列表）

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
            Text("每次启动一份日志文件，都在应用 Documents/Logs 文件夹里；上次启动没完成就崩了会留下来，下次启动能看到死在哪一步。")
        }
        .sheet(isPresented: $showingLog) {
            StartupDiagLogListView()
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

/// 日志文件列表（最新在前）：崩溃徽章＋大小，点进看全文。
/// 0.2.31：原来只读最新一份全文，现在列出 Logs 文件夹里的全部文件。
/// 0.2.37：点一次就开——之前是旧式 destination-NavigationLink 放在 sheet 内
/// 的 List 里，首点只选中行（List 行选择把点吞了）、第二点才导航；改 value-based
///（NavigationLink(value:) + navigationDestination），首点即导航。
private struct StartupDiagLogListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [SBDiagLogFile] = []
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if files.isEmpty {
                    Text("暂无日志")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(files) { file in
                        NavigationLink(value: file) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.displayName)
                                        .font(.subheadline)
                                    Text(file.displaySize)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if file.crashed {
                                    Text("崩溃")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.red, in: Capsule())
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("启动日志")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SBDiagLogFile.self) { file in
                StartupDiagLogDetailView(file: file)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                files = SBDiagLog.fileList()
            }
        }
    }
}

/// 单份启动日志全文页：等宽字、可选文本、复制与系统分享。
private struct StartupDiagLogDetailView: View {
    let file: SBDiagLogFile
    @Environment(\.dismiss) private var dismiss
    @State private var logText = ""
    @State private var copied = false

    var body: some View {
        ScrollView {
            Text(logText.isEmpty ? "暂无日志" : logText)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle(file.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
            logText = SBDiagLog.readFile(file.name) ?? ""
        }
    }
}
