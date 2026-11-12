//
//  LCSettingsView.swift
//  LiveContainerSwiftUI
//
//  SealBox Settings — iOS-native grouped list (dev doc §12).
//  Only real features are shown; anything without real data shows an
//  empty state instead of mock data (§12.4).
//
//  JIT: status display only. JIT is enabled from Seal (§7.3); there is
//  no JIT switch inside SealBox, and no reliable JIT status signal is
//  exposed to Swift, so the JIT group shows a neutral "unknown" state
//  and never claims JIT is on.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

enum JITEnablerType : Int, CaseIterable, Identifiable {
    var id: Int { rawValue }
    case SideJITServer = 0
    case StikJIT = 1
    case JITStreamerEBLegacy = 2
    case StikJITLC = 3
    case SideStore = 4
    case StosDebug = 5
    case StosDebugLC = 6

    var displayName: String {
        switch self {
        case .StikJIT: "StikDebug"
        case .StikJITLC: "StikDebug (Another SealBox/Multitask)"
        case .StosDebug: "StosDebug"
        case .StosDebugLC: "StosDebug (Another SealBox/Multitask)"
        case .SideStore: "SideStore"
        case .JITStreamerEBLegacy: "JitStreamer-EB (Relaunch)"
        case .SideJITServer: "SideJITServer/JITStreamer 2.0"
        }
    }
}

/// Deep link that hands an IPA file URL or an IPA download URL to the
/// desktop install flow (LCAppListView.handleURL → installFromUrl).
/// Shared by the file picker and the install-from-link form.
func sealBoxInstallDeepLink(for targetURL: URL) -> URL? {
    var components = URLComponents()
    components.scheme = "sealbox"
    components.host = "install"
    components.queryItems = [URLQueryItem(name: "url", value: targetURL.absoluteString)]
    return components.url
}

/// One row of the settings list, with the text the real-time search
/// filter matches against.
private struct SBSettingsRow: Identifiable {
    let id: String
    let searchText: String
    let content: AnyView
}

private struct SBSettingsSection: Identifiable {
    let id: String
    let title: String
    let footer: String?
    let rows: [SBSettingsRow]
}

struct LCSettingsView: View {
    @State var errorShow = false
    @State var errorInfo = ""
    @State var successShow = false
    @State var successInfo = ""

    @State private var certificateDataFound = false
    @State private var certTeamId: String?
    @State private var certStatus: Int = -1
    @State private var certValidUntil: String?
    @State private var certLastUpdateDateStr: String?
    @State private var tweakItemCount = 0
    @State private var searchText = ""

    @StateObject private var wallpaperStore = LCDesktopWallpaperStore()
    @State private var showWallpaperPicker = false
    @State private var showRestoreWallpaperDialog = false
    @State private var choosingIPA = false

    @StateObject private var certificateImportAlert = YesNoHelper()
    @StateObject private var certificateImportFromBuiltInSideStoreAlert = YesNoHelper()
    @StateObject private var certificateRemoveAlert = YesNoHelper()
    @StateObject private var certificateImportFileAlert = AlertHelper<URL>()
    @StateObject private var certificateImportPasswordAlert = InputHelper()

    @AppStorage("LCFrameShortcutIcons") var frameShortIcon = false
    @AppStorage("LCSwitchAppWithoutAsking") var silentSwitchApp = false
    @AppStorage("LCOpenWebPageWithoutAsking") var silentOpenWebPage = false
    @AppStorage("LCDontSignApp", store: LCUtils.appGroupUserDefault) var dontSignApp = false
    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    @AppStorage("LCDesktopTheme", store: LCUtils.appGroupUserDefault) var desktopTheme = LCDesktopTheme.system

    @EnvironmentObject private var sharedModel : SharedModel
    @Environment(\.dismiss) private var dismiss

    @State private var isViewAppeared = false

    @State var store : Store = .Unknown

    let storeName = LCUtils.getStoreName()

    init() {
        _certificateDataFound = State(initialValue: LCUtils.certificateData() != nil)
        _store = State(initialValue: LCUtils.store())
    }

    // MARK: - Section model

    private var certificateStatusText: String {
        certificateDataFound
            ? "lc.settings.sealbox.certificateImported".loc
            : "lc.settings.sealbox.noCertificate".loc
    }

    private var certificateStatusColor: Color {
        certificateDataFound ? .green : .secondary
    }

    private var certificateValidityText: String? {
        guard certificateDataFound, certStatus != -1 else { return nil }
        switch certStatus {
        case 0: return "lc.jitlessDiag.certificateValid".loc
        case 1: return "lc.jitlessDiag.certificateRevoked".loc
        default: return "lc.common.unknown".loc
        }
    }

    /// Version straight from the bundle (CFBundleShortVersionString and
    /// CFBundleVersion). Not from LCVersionInfo, which
    /// is not present in Info.plist.
    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        if short.isEmpty { return build }
        if short == build { return short }
        return "\(short) (\(build))"
    }

    private var sections: [SBSettingsSection] {
        var result: [SBSettingsSection] = []

        // MARK: 证书 / 签名身份
        var certRows: [SBSettingsRow] = []
        certRows.append(SBSettingsRow(
            id: "cert-status",
            searchText: "lc.settings.sealbox.certificate".loc + " " + certificateStatusText,
            content: AnyView(
                VStack(alignment: .leading, spacing: 4) {
                    sbLabel("lc.settings.sealbox.certificate".loc, icon: "signature", color: .blue)
                    Text(certificateStatusText)
                        .foregroundStyle(certificateStatusColor)
                        .font(.subheadline)
                }
            )
        ))
        if certificateDataFound {
            if let teamId = certTeamId {
                certRows.append(sbValueRow(
                    id: "cert-team",
                    searchText: "lc.jitlessDiag.certTeamId".loc + " " + teamId,
                    title: "lc.jitlessDiag.certTeamId".loc, icon: "person.fill", color: .blue,
                    value: teamId
                ))
            }
            if let validity = certificateValidityText {
                let value = certValidUntil.map { validity + " · " + $0 } ?? validity
                certRows.append(sbValueRow(
                    id: "cert-valid",
                    searchText: "lc.jitlessDiag.certificateStatus".loc + " " + value,
                    title: "lc.jitlessDiag.certificateStatus".loc, icon: "checkmark.seal.fill", color: .blue,
                    value: value, valueColor: certStatus == 0 ? .green : .red
                ))
            }
            if let updated = certLastUpdateDateStr {
                certRows.append(sbValueRow(
                    id: "cert-updated",
                    searchText: "lc.jitlessDiag.certLastUpdate".loc + " " + updated,
                    title: "lc.jitlessDiag.certLastUpdate".loc, icon: "clock.fill", color: .blue,
                    value: updated
                ))
            }
        }
        if certificateDataFound {
            certRows.append(sbButtonRow(
                id: "cert-remove",
                searchText: "lc.settings.removeCertificate".loc,
                title: "lc.settings.removeCertificate".loc, icon: "trash.fill", color: .red,
                role: .destructive
            ) {
                Task { await removeCertificate() }
            })
        } else {
            certRows.append(sbButtonRow(
                id: "cert-import",
                searchText: "lc.settings.importCertificate".loc,
                title: "lc.settings.importCertificate".loc, icon: "square.and.arrow.down.fill", color: .blue
            ) {
                Task { await importCertificate() }
            })
        }
        if store == .AltStore || store == .SideStore {
            let title = certificateDataFound
                ? "lc.settings.refreshCertificateFromStore %@".localizeWithFormat(storeName)
                : "lc.settings.importCertificateFromStore %@".localizeWithFormat(storeName)
            certRows.append(sbButtonRow(
                id: "cert-store",
                searchText: title,
                title: title, icon: "arrow.triangle.2.circlepath", color: .blue
            ) {
                Task { await importCertificateFromSideStore() }
            })
        }
        certRows.append(sbToggleRow(
            id: "dont-sign",
            searchText: "lc.settings.dontSign".loc,
            title: "lc.settings.dontSign".loc, icon: "nosign", color: .blue,
            isOn: $dontSignApp
        ))
        result.append(SBSettingsSection(
            id: "certificate",
            title: "lc.settings.sealbox.certificate".loc,
            footer: "lc.settings.jitLessDesc".loc,
            rows: certRows
        ))

        // MARK: JIT — status display only, no enabler in SealBox (§7.3).
        // There is no reliable JIT status signal exposed to Swift
        // (checkJITEnabled() is a static C function in LCBootstrap.m),
        // so the status stays neutral "unknown" instead of claiming on.
        // No diagnose page: the JIT-less diagnose view was a
        // LiveContainer leftover and is deleted; the certificate rows
        // above already show the same real certificate state.
        result.append(SBSettingsSection(
            id: "jit",
            title: "JIT",
            footer: "lc.settings.sealbox.jitDesc".loc,
            rows: [
                sbValueRow(
                    id: "jit-status",
                    searchText: "lc.settings.sealbox.jitStatus".loc + " " + "lc.common.unknown".loc,
                    title: "lc.settings.sealbox.jitStatus".loc, icon: "bolt.fill", color: .yellow,
                    value: "lc.common.unknown".loc
                ),
            ]
        ))

        // MARK: 容器数据管理
        var containerRows: [SBSettingsRow] = []
        containerRows.append(sbNavRow(
            id: "storage",
            searchText: "lc.settings.storageManagement".loc,
            title: "lc.settings.storageManagement".loc, icon: "externaldrive.fill", color: .green
        ) {
            LCStorageManagementView()
        })
        containerRows.append(sbNavRow(
            id: "data",
            searchText: "lc.settings.dataManagement".loc,
            title: "lc.settings.dataManagement".loc, icon: "folder.fill", color: .green
        ) {
            LCDataManagementView()
        })
        // SealBox is a single app: there is no multi-LiveContainer
        // management page (deleted with LCMultiLCManagementView).
        result.append(SBSettingsSection(
            id: "containers",
            title: "lc.settings.sealbox.containers".loc,
            footer: nil,
            rows: containerRows
        ))

        // MARK: 安装入口
        result.append(SBSettingsSection(
            id: "install",
            title: "lc.settings.sealbox.install".loc,
            footer: "lc.settings.sealbox.installLinkHint".loc,
            rows: [
                sbButtonRow(
                    id: "import-ipa",
                    searchText: "lc.settings.sealbox.importIpa".loc,
                    title: "lc.settings.sealbox.importIpa".loc, icon: "square.and.arrow.down.fill", color: .purple
                ) {
                    choosingIPA = true
                },
                sbNavRow(
                    id: "install-link",
                    searchText: "lc.settings.sealbox.installFromLink".loc,
                    title: "lc.settings.sealbox.installFromLink".loc, icon: "link", color: .purple
                ) {
                    SBInstallFromLinkView()
                },
            ]
        ))

        // MARK: 插件模块
        let tweakSubtitle = tweakItemCount == 0 ? "lc.settings.sealbox.noTweaks".loc : nil
        result.append(SBSettingsSection(
            id: "plugins",
            title: "lc.settings.sealbox.plugins".loc,
            footer: "lc.tweakView.globalFolderDesc".loc,
            rows: [
                sbNavRow(
                    id: "tweaks",
                    searchText: "lc.settings.sealbox.plugins".loc + " " + (tweakSubtitle ?? ""),
                    title: "lc.settings.sealbox.plugins".loc, icon: "wrench.and.screwdriver", color: .orange,
                    subtitle: tweakSubtitle
                ) {
                    LCTweaksView()
                },
            ]
        ))

        // MARK: 外观 — same stores as the desktop "···" menu (§8.4):
        // theme in App Group UserDefaults "LCDesktopTheme", wallpaper
        // in LCDesktopWallpaperStore. Changing one place changes both.
        var appearanceRows: [SBSettingsRow] = []
        appearanceRows.append(SBSettingsRow(
            id: "theme",
            searchText: "lc.settings.sealbox.theme".loc,
            content: AnyView(
                Picker(selection: $desktopTheme) {
                    ForEach(LCDesktopTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                } label: {
                    sbLabel("lc.settings.sealbox.theme".loc, icon: "moon.circle.fill", color: .pink)
                }
            )
        ))
        appearanceRows.append(sbValueRow(
            id: "wallpaper",
            searchText: "lc.settings.sealbox.wallpaper".loc,
            title: "lc.settings.sealbox.wallpaper".loc, icon: "photo.fill", color: .pink,
            value: wallpaperStore.hasCustomWallpaper
                ? "lc.settings.sealbox.wallpaperCustom".loc
                : "lc.settings.sealbox.wallpaperDefault".loc
        ))
        appearanceRows.append(sbButtonRow(
            id: "change-wallpaper",
            searchText: "lc.settings.sealbox.changeWallpaper".loc,
            title: "lc.settings.sealbox.changeWallpaper".loc, icon: "photo.fill", color: .pink
        ) {
            showWallpaperPicker = true
        })
        appearanceRows.append(sbButtonRow(
            id: "reset-wallpaper",
            searchText: "lc.settings.sealbox.resetWallpaper".loc,
            title: "lc.settings.sealbox.resetWallpaper".loc, icon: "arrow.counterclockwise", color: .pink,
            role: .destructive,
            disabled: !wallpaperStore.hasCustomWallpaper
        ) {
            showRestoreWallpaperDialog = true
        })
        appearanceRows.append(sbToggleRow(
            id: "dynamic-colors",
            searchText: "lc.settings.dynamicColors".loc,
            title: "lc.settings.dynamicColors".loc, icon: "paintpalette.fill", color: .pink,
            isOn: $dynamicColors
        ))
        if #available(iOS 18.0, *) {
            appearanceRows.append(sbToggleRow(
                id: "dark-mode-icon",
                searchText: "lc.settings.darkModeIcon".loc,
                title: "lc.settings.darkModeIcon".loc, icon: "moon.fill", color: .pink,
                isOn: $darkModeIcon
            ))
        }
        appearanceRows.append(sbToggleRow(
            id: "frame-icon",
            searchText: "lc.settings.FrameIcon".loc,
            title: "lc.settings.FrameIcon".loc, icon: "square.dashed", color: .pink,
            isOn: $frameShortIcon
        ))
        result.append(SBSettingsSection(
            id: "appearance",
            title: "lc.settings.sealbox.appearance".loc,
            footer: "lc.settings.dynamicColors.desc".loc,
            rows: appearanceRows
        ))

        // MARK: 高级
        // 修复文件选择器 / 修复本地通知 are per-app switches in each
        // app's own settings page (§13); there is no global switch for
        // them, so this group does not invent one (see footer).
        // There is no log store in the codebase, so no log-export row
        // is shown either — a row with nothing real to export would
        // be a fake feature.
        var advancedRows: [SBSettingsRow] = []
        advancedRows.append(sbToggleRow(
            id: "silent-switch",
            searchText: "lc.settings.silentSwitchApp".loc,
            title: "lc.settings.silentSwitchApp".loc, icon: "arrow.left.arrow.right", color: .gray,
            isOn: $silentSwitchApp
        ))
        advancedRows.append(sbToggleRow(
            id: "silent-open-page",
            searchText: "lc.settings.silentOpenWebPage".loc,
            title: "lc.settings.silentOpenWebPage".loc, icon: "globe", color: .gray,
            isOn: $silentOpenWebPage
        ))
        advancedRows.append(sbButtonRow(
            id: "clear-notifications",
            searchText: "lc.settings.clearNotifications".loc,
            title: "lc.settings.clearNotifications".loc, icon: "bell.slash.fill", color: .gray
        ) {
            clearNotifications()
        })
        result.append(SBSettingsSection(
            id: "advanced",
            title: "lc.settings.sealbox.advanced".loc,
            footer: "lc.settings.sealbox.perAppFixes".loc,
            rows: advancedRows
        ))

        // MARK: 关于
        result.append(SBSettingsSection(
            id: "about",
            title: "lc.settings.about".loc,
            footer: "lc.settings.warning".loc + "\n" + "lc.settings.sealbox.dataRisk".loc,
            rows: [
                SBSettingsRow(
                    id: "version",
                    searchText: "lc.settings.sealbox.version".loc + " " + appVersionText,
                    content: AnyView(
                        HStack {
                            sbLabel("lc.settings.sealbox.version".loc, icon: "info.circle.fill", color: .teal)
                            Spacer()
                            Text(appVersionText)
                                .foregroundStyle(.secondary)
                        }
                    )
                ),
                sbNavRow(
                    id: "license",
                    searchText: "lc.settings.sealbox.license".loc + " AGPL-3.0",
                    title: "lc.settings.sealbox.license".loc, icon: "doc.text.fill", color: .teal,
                    subtitle: "AGPL-3.0"
                ) {
                    SBSealBoxLicenseView()
                },
                sbButtonRow(
                    id: "source-code",
                    searchText: "lc.settings.sealbox.sourceCode".loc,
                    title: "lc.settings.sealbox.sourceCode".loc, icon: "chevron.left.forwardslash.chevron.right", color: .teal
                ) {
                    openSealBoxGitHub()
                },
                SBSettingsRow(
                    id: "github",
                    searchText: "3188447354/SealBox GitHub",
                    content: AnyView(
                        HStack {
                            Image("GitHub")
                            Button("3188447354/SealBox") {
                                openSealBoxGitHub()
                            }
                        }
                    )
                ),
            ]
        ))

        return result
    }

    private var filteredSections: [SBSettingsSection] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let rows = section.rows.filter {
                $0.searchText.localizedCaseInsensitiveContains(query)
                    || section.title.localizedCaseInsensitiveContains(query)
            }
            guard !rows.isEmpty else { return nil }
            return SBSettingsSection(id: section.id, title: section.title, footer: section.footer, rows: rows)
        }
    }

    // MARK: - Row builders

    private func sbIcon(_ systemName: String, _ color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func sbLabel(_ title: String, icon: String, color: Color) -> some View {
        Label {
            Text(title)
        } icon: {
            sbIcon(icon, color)
        }
    }

    private func sbValueRow(id: String, searchText: String, title: String, icon: String, color: Color, value: String, valueColor: Color = .secondary) -> SBSettingsRow {
        SBSettingsRow(
            id: id,
            searchText: searchText,
            content: AnyView(
                HStack {
                    sbLabel(title, icon: icon, color: color)
                    Spacer()
                    Text(value)
                        .foregroundStyle(valueColor)
                }
            )
        )
    }

    private func sbButtonRow(id: String, searchText: String, title: String, icon: String, color: Color, role: ButtonRole? = nil, disabled: Bool = false, action: @escaping () -> Void) -> SBSettingsRow {
        SBSettingsRow(
            id: id,
            searchText: searchText,
            content: AnyView(
                Button(role: role, action: action) {
                    sbLabel(title, icon: icon, color: color)
                }
                .disabled(disabled)
            )
        )
    }

    private func sbToggleRow(id: String, searchText: String, title: String, icon: String, color: Color, isOn: Binding<Bool>) -> SBSettingsRow {
        SBSettingsRow(
            id: id,
            searchText: searchText,
            content: AnyView(
                Toggle(isOn: isOn) {
                    sbLabel(title, icon: icon, color: color)
                }
            )
        )
    }

    private func sbNavRow<D: View>(id: String, searchText: String, title: String, icon: String, color: Color, subtitle: String? = nil, disabled: Bool = false, @ViewBuilder destination: @escaping () -> D) -> SBSettingsRow {
        SBSettingsRow(
            id: id,
            searchText: searchText,
            content: AnyView(
                NavigationLink {
                    destination()
                } label: {
                    HStack {
                        sbLabel(title, icon: icon, color: color)
                        Spacer()
                        if let subtitle {
                            Text(subtitle)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(disabled)
            )
        )
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            List {
                ForEach(filteredSections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            row.content
                        }
                    } header: {
                        Text(section.title)
                    } footer: {
                        if let footer = section.footer {
                            Text(footer)
                        }
                    }
                }

            }
            .listStyle(.insetGrouped)
            .navigationTitle("lc.tabView.settings".loc)
            .searchable(text: $searchText, prompt: "lc.settings.sealbox.searchPrompt".loc)
            .alert("lc.common.error".loc, isPresented: $errorShow){
            } message: {
                Text(errorInfo)
            }
            .alert("lc.common.success".loc, isPresented: $successShow){
            } message: {
                Text(successInfo)
            }
            .alert("lc.settings.importCertificate".loc, isPresented: $certificateImportAlert.show) {
                Button {
                    certificateImportAlert.close(result: true)
                } label: {
                    Text("lc.common.ok".loc)
                }

                Button("lc.common.cancel".loc, role: .cancel) {
                    certificateImportAlert.close(result: false)
                }
            } message: {
                Text("lc.settings.importCertificateDesc".loc)
            }
            .alert("lc.settings.removeCertificate".loc, isPresented: $certificateRemoveAlert.show) {
                Button(role: .destructive) {
                    certificateRemoveAlert.close(result: true)
                } label: {
                    Text("lc.common.ok".loc)
                }

                Button("lc.common.cancel".loc, role: .cancel) {
                    certificateRemoveAlert.close(result: false)
                }
            } message: {
                Text("lc.settings.removeCertificateDesc".loc)
            }
            .alert("lc.settings.importCertFromBuiltinSideStore".loc, isPresented: $certificateImportFromBuiltInSideStoreAlert.show) {
                Button {
                    certificateImportFromBuiltInSideStoreAlert.close(result: true)
                } label: {
                    Text("lc.common.ok".loc)
                }
                Button("lc.common.cancel".loc, role: .cancel) {
                    certificateImportFromBuiltInSideStoreAlert.close(result: false)
                }
            } message: {
                Text("lc.settings.importCertFromBuiltinSideStoreDesc".loc)
            }
            .betterFileImporter(isPresented: $certificateImportFileAlert.show, types: [.p12], multiple: false, callback: { fileUrls in
                certificateImportFileAlert.close(result: fileUrls[0])
            }, onDismiss: {
                certificateImportFileAlert.close(result: nil)
            })
            .textFieldAlert(
                isPresented: $certificateImportPasswordAlert.show,
                title: "lc.settings.importCertificateInputPassword".loc,
                text: $certificateImportPasswordAlert.initVal,
                placeholder: "",
                action: { newText in
                    certificateImportPasswordAlert.close(result: newText)
                },
                actionCancel: {_ in
                    certificateImportPasswordAlert.close(result: nil)
                    certificateImportPasswordAlert.show = false
                }
            )
            .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
                if let fileUrl = fileUrls.first {
                    handOffInstall(targetURL: fileUrl)
                }
            }, onDismiss: {
                choosingIPA = false
            })
            .sheet(isPresented: $showWallpaperPicker) {
                LCPhotoPicker(isPresented: $showWallpaperPicker) { image in
                    wallpaperStore.apply(image: image)
                }
            }
            .confirmationDialog("lc.settings.sealbox.resetWallpaper".loc, isPresented: $showRestoreWallpaperDialog) {
                Button("lc.settings.sealbox.resetWallpaper".loc, role: .destructive) {
                    wallpaperStore.resetToDefault()
                }
                Button("lc.common.cancel".loc, role: .cancel) {}
            } message: {
                Text("lc.settings.sealbox.resetWallpaperDesc".loc)
            }
            .onAppear {
                refreshOnAppear()
            }
            .onChange(of: sharedModel.deepLink) { link in
                // Only the certificate callback belongs to Settings.
                // Install links are consumed by the desktop (LCAppListView);
                // never nil them here.
                guard sharedModel.requestedSystemPage == .settings, let link, link.host == "certificate" else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    // MARK: - Refresh

    private func refreshOnAppear() {
        refreshCertificateInfo()
        refreshTweakCount()
        if !isViewAppeared {
            if sharedModel.requestedSystemPage == .settings, let link = sharedModel.deepLink, link.host == "certificate" {
                sharedModel.deepLink = nil
                handleURL(url: link)
            }
            isViewAppeared = true
        }
    }

    private func refreshTweakCount() {
        tweakItemCount = (try? FileManager.default.contentsOfDirectory(atPath: LCPath.tweakPath.path).count) ?? 0
    }

    /// Re-reads the real certificate state (same sources as the
    /// JIT-less diagnose page) for the certificate rows.
    private func refreshCertificateInfo() {
        certificateDataFound = LCUtils.certificateData() != nil
        if let lastUpdateDate = LCUtils.appGroupUserDefault.object(forKey: "LCCertificateUpdateDate") as? Date {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            certLastUpdateDateStr = formatter.string(from: lastUpdateDate)
        } else {
            certLastUpdateDateStr = nil
        }
        certStatus = -1
        certTeamId = nil
        certValidUntil = nil
        guard certificateDataFound else { return }
        _ = LCUtils.validateCertificate { status, date, ou, error in
            DispatchQueue.main.async {
                if let error {
                    errorInfo = error.loc
                    errorShow = true
                    certStatus = 2
                    return
                }
                certStatus = Int(status)
                if let date {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .short
                    formatter.timeStyle = .medium
                    certValidUntil = formatter.string(from: date)
                }
                if let ou {
                    certTeamId = ou
                }
            }
        }
    }

    /// Hands an IPA file to the desktop install flow: dismiss Settings,
    /// go back to the desktop, then deliver the install deep link
    /// for LCAppListView to consume.
    private func handOffInstall(targetURL: URL) {
        guard let installURL = sealBoxInstallDeepLink(for: targetURL) else { return }
        dismiss()
        sharedModel.requestedSystemPage = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            sharedModel.deepLink = installURL
        }
    }

    func openSealBoxGitHub() {
        UIApplication.shared.open(URL(string: "https://github.com/3188447354/SealBox")!)
    }

    func clearNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllDeliveredNotifications()
        notificationCenter.removeAllPendingNotificationRequests()
        if #available(iOS 16.0, *) {
            notificationCenter.setBadgeCount(0)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    func importCertificate() async {
        guard let doImport = await certificateImportAlert.open(), doImport else {
            return
        }
        guard let certificateURL = await certificateImportFileAlert.open() else {
            return
        }
        guard let certificatePassword = await certificateImportPasswordAlert.open() else {
            return
        }
        let certificateData : Data
        do {
            certificateData = try Data(contentsOf: certificateURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }

        guard let _ = LCUtils.getCertTeamId(withKeyData: certificateData, password: certificatePassword) else {
            errorInfo = "lc.settings.invalidCertError".loc
            errorShow = true
            return
        }

        LCUtils.appGroupUserDefault.set(certificateData, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(certificatePassword, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(NSDate.now, forKey: "LCCertificateUpdateDate")
        certificateDataFound = true
        refreshCertificateInfo()

        UserDefaults.standard.set(LCSharedUtils.appGroupID(), forKey: "LCAppGroupID")
    }

    func importCertificateFromSideStore() async {
        if UserDefaults.sideStoreExist() {
            if let ans = await certificateImportFromBuiltInSideStoreAlert.open(), ans {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: "signingCertificate",
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecAttrService as String: "com.mjorb.sealbox",
                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
                ]

                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)

                guard status == errSecSuccess else {
                    if status == errSecItemNotFound {
                        errorInfo = "lc.settings.importCertFromBuiltinSideStore.certNotFounndErr".loc
                        errorShow = true
                    } else {
                        errorInfo = "Keychain read error: \(status)"
                        errorShow = true
                    }
                    return
                }

                guard let data = item as? Data else {
                    errorInfo = "Failed to decode certificate data"
                    errorShow = true
                    return
                }

                let passwordQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrAccount as String: "signingCertificatePassword",
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne,
                    kSecAttrService as String: "com.mjorb.sealbox",
                    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
                ]

                var passwordItem: CFTypeRef?
                let passwordStatus = SecItemCopyMatching(passwordQuery as CFDictionary, &passwordItem)
                var password = ""
                if passwordStatus == errSecSuccess,
                   let passwordData = passwordItem as? Data,
                   let pwd = String(data: passwordData, encoding: .utf8) {
                    password = pwd
                }

                onSideStoreCertificateCallback(certificateData: data, password: password)

                return
            }
        }

        let storeScheme : String
        if store == .AltStore {
            storeScheme = "altstore-classic"
        } else {
            storeScheme = "sidestore"
        }

        guard let url = URL(string: "\(storeScheme.lowercased())://certificate?callback_template=sealbox%3A%2F%2Fcertificate%3Fcert%3D%24%28BASE64_CERT%29%26password%3D%24%28PASSWORD%29") else {
            errorInfo = "Failed to initialize certificate import URL."
            errorShow = true
            return
        }
        await UIApplication.shared.open(url)
    }

    func onSideStoreCertificateCallback(certificateData: Data, password: String) {
        LCUtils.appGroupUserDefault.set(certificateData, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(password, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(NSDate.now, forKey: "LCCertificateUpdateDate")
        certificateDataFound = true
        refreshCertificateInfo()
    }

    func removeCertificate() async {
        guard let doRemove = await certificateRemoveAlert.open(), doRemove else {
            return
        }

        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(nil, forKey: "LCCertificateUpdateDate")
        certificateDataFound = false
        certTeamId = nil
        certStatus = -1
        certValidUntil = nil
        certLastUpdateDateStr = nil

        UserDefaults.standard.set(nil, forKey: "LCAppGroupID")
    }

    func handleURL(url: URL) {
        if url.host == "certificate" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let encodedCert = queryItems["cert"]?.removingPercentEncoding,
                      let password = queryItems["password"],
                      let certData = Data(base64Encoded: encodedCert)
                else { return }

                onSideStoreCertificateCallback(certificateData: certData, password: password)

            }
        }
    }
}

/// Install an IPA from a download link. The link is handed to the same
/// desktop install flow as a picked file (sealbox://install?url=…).
struct SBInstallFromLinkView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var showInvalidAlert = false

    var body: some View {
        Form {
            Section {
                TextField("lc.settings.sealbox.installLinkPlaceholder".loc, text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("lc.settings.sealbox.installFromLink".loc) {
                    install()
                }
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text("lc.settings.sealbox.installLinkHint".loc)
            }
        }
        .navigationTitle("lc.settings.sealbox.installFromLink".loc)
        .navigationBarTitleDisplayMode(.inline)
        .alert("lc.common.error".loc, isPresented: $showInvalidAlert) {
            Button("lc.common.ok".loc, role: .cancel) {}
        } message: {
            Text("lc.settings.sealbox.invalidLink".loc)
        }
    }

    private func install() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = URL(string: trimmed),
              let scheme = target.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let installURL = sealBoxInstallDeepLink(for: target) else {
            showInvalidAlert = true
            return
        }
        dismiss()
        sharedModel.requestedSystemPage = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            sharedModel.deepLink = installURL
        }
    }
}

/// AGPL-3.0 licence page. The full text is shown from the bundled
/// LICENSE file when the build includes it; otherwise the page links
/// to the licence text and the source repository instead of showing
/// a placeholder.
struct SBSealBoxLicenseView: View {
    @State private var licenseText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("lc.settings.sealbox.licenseIntro".loc)
                if let licenseText {
                    Text(licenseText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Link("lc.settings.sealbox.licenseFullText".loc, destination: URL(string: "https://github.com/3188447354/SealBox/blob/main/LICENSE")!)
                    Link("AGPL-3.0 (gnu.org)", destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!)
                }
                Link("lc.settings.sealbox.sourceCode".loc, destination: URL(string: "https://github.com/3188447354/SealBox")!)
            }
            .padding()
        }
        .navigationTitle("lc.settings.sealbox.license".loc)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if licenseText == nil {
                // The bundled copy is Resources/LICENSE.txt (AGPL-3.0
                // verbatim); an extensionless LICENSE is also accepted
                // so an older/alternate bundle layout still works.
                let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt")
                    ?? Bundle.main.url(forResource: "LICENSE", withExtension: nil)
                if let url {
                    licenseText = try? String(contentsOf: url)
                }
            }
        }
    }
}
