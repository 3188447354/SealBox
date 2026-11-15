//
//  ShareExtensionViews.swift
//  ShareExtension
//
//  SealBox 0.0.3 rebuild — share-to-install sheet only
//  (implementation #2).
//
//  One card: the .ipa file (name + size) or the remote direct link,
//  an "安装到 SealBox" button, and Cancel. No app grid, no container
//  picker, no SideStore entry — the extension no longer launches guest
//  apps, it only hands an IPA to the host for install.

import SwiftUI
import UIKit

struct ShareExtensionRootView: View {
    @ObservedObject var viewModel: ShareExtensionViewModel
    let extensionContext: NSExtensionContext?

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                switch viewModel.payload.kind {
                case .loading:
                    ProgressView("正在读取…")
                        .padding(.top, 40)
                case .file:
                    if viewModel.isWorking && viewModel.staged == nil {
                        ProgressView("正在准备文件…")
                            .padding(.top, 40)
                    } else if let staged = viewModel.staged {
                        installCard(
                            title: staged.originalName,
                            subtitle: ByteCountFormatter.string(fromByteCount: staged.size, countStyle: .file)
                        )
                    } else {
                        ProgressView("正在准备文件…")
                            .padding(.top, 40)
                    }
                case .remoteIPA(let url):
                    installCard(
                        title: url.lastPathComponent,
                        subtitle: url.host ?? url.absoluteString
                    )
                case .empty:
                    Text("没有可安装的文件。\n请分享一个 .ipa 文件。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                case .failed(let message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text(message)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)
                }
                if viewModel.didOpenHost {
                    Text("已在 SealBox 中打开，正在安装…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle("SealBox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        viewModel.cancelRequest()
                    }
                }
            }
            .alert("错误", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    private func installCard(title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .padding(.top, 24)
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("安装到 SealBox") {
                Task {
                    await viewModel.install(context: extensionContext)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isWorking)
            Text("将直接进入安装，不用再选文件。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
