import SwiftUI
import Foundation
import WebKit

// Dock apps (0.1.7): Phone, Safari, Messages, Music.
// All four open full-screen via VMApp and return home with the root
// view's bottom swipe-up gesture.
//
// NO FAKE DATA (MJ 2026-11-18, highest priority): contacts, conversations,
// songs and call records only ever contain what the user typed or did
// inside the VM. Empty states say so instead of pre-filled entries.
// Music shows player state only — it never pretends to play audio.

// MARK: - Phone

/// One call the user actually made inside the VM (persisted).
struct VMCallRecord: Codable, Hashable, Identifiable {
    var id: String { "\(date.timeIntervalSince1970)-\(number)" }
    let number: String
    let date: Date
    let duration: TimeInterval
}

private enum PhoneCallStore {
    static let key = "vm.phone.calls"

    static func load() -> [VMCallRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([VMCallRecord].self, from: data) else { return [] }
        return records
    }

    static func append(_ record: VMCallRecord) {
        var records = load()
        records.insert(record, at: 0)
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct PhoneAppView: View {
    @State private var number = ""
    @State private var calls: [VMCallRecord] = []
    @State private var callingNumber: String? = nil

    private let keys: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["*", "0", "#"],
    ]

    var body: some View {
        Group {
            if let calling = callingNumber {
                CallView(number: calling) { duration in
                    PhoneCallStore.append(VMCallRecord(number: calling, date: Date(), duration: duration))
                    calls = PhoneCallStore.load()
                    callingNumber = nil
                }
            } else {
                dialPad
            }
        }
        .onAppear { calls = PhoneCallStore.load() }
    }

    private var dialPad: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text(number.isEmpty ? " " : number)
                    .font(.system(size: 32, weight: .light))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.top, 48)

                ForEach(keys, id: \.self) { row in
                    HStack(spacing: 28) {
                        ForEach(row, id: \.self) { key in
                            Button {
                                if number.count < 20 { number.append(key) }
                            } label: {
                                Text(key)
                                    .font(.system(size: 30, weight: .light))
                                    .foregroundStyle(.primary)
                                    .frame(width: 72, height: 72)
                                    .background(Color(.secondarySystemFill), in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack(spacing: 28) {
                    Button {
                        if !number.isEmpty { callingNumber = number }
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(number.isEmpty ? Color.gray : Color.green, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(number.isEmpty)
                    Button {
                        if !number.isEmpty { number.removeLast() }
                    } label: {
                        Image(systemName: "delete.left.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.primary)
                            .frame(width: 72, height: 72)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("最近通话")
                        .font(.headline)
                    if calls.isEmpty {
                        Text("暂无通话记录")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(calls) { call in
                            HStack {
                                Text(call.number)
                                Spacer()
                                Text("\(VMTime.dateTimeString(for: call.date)) · \(VMTime.mmss(call.duration))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 8)

                Text("仅虚拟机内演示，不会拨打真实电话。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

/// In-call page: the timer is the real elapsed time since the call started.
private struct CallView: View {
    let number: String
    let onHangup: (TimeInterval) -> Void
    @State private var startDate = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 24) {
                Spacer()
                Text(number)
                    .font(.system(size: 32, weight: .light))
                Text("正在呼叫 · \(VMTime.mmss(context.date.timeIntervalSince(startDate)))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onHangup(context.date.timeIntervalSince(startDate))
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Color.red, in: Circle())
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - Safari

/// Web view state shared between the SwiftUI wrapper and the toolbar.
final class SafariStore: ObservableObject {
    let webView: WKWebView
    private let delegate: SafariDelegate
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var addressText = ""

    init() {
        let webView = WKWebView()
        self.webView = webView
        self.delegate = SafariDelegate()
        self.delegate.store = self
        webView.navigationDelegate = delegate
    }

    /// Load what the user typed; a bare host gets https:// prepended.
    func load(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var target = trimmed
        if !target.contains("://") { target = "https://" + target }
        guard let url = URL(string: target) else { return }
        webView.load(URLRequest(url: url))
    }

    /// Called by the delegate on the main thread after each navigation event.
    func updateState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        if let url = webView.url {
            addressText = url.absoluteString
        }
    }
}

private final class SafariDelegate: NSObject, WKNavigationDelegate {
    weak var store: SafariStore?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        store?.updateState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        store?.updateState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        store?.updateState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        store?.updateState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        store?.updateState()
    }
}

private struct SafariWebView: UIViewRepresentable {
    @ObservedObject var store: SafariStore

    func makeUIView(context: Context) -> WKWebView { store.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct SafariAppView: View {
    @StateObject private var store = SafariStore()
    @State private var addressDraft = ""
    @State private var didLoadInitial = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { store.webView.goBack() } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!store.canGoBack)
                Button { store.webView.goForward() } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!store.canGoForward)
                TextField("搜索或输入网址", text: $addressDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onSubmit { store.load(addressDraft) }
                if store.isLoading {
                    ProgressView()
                }
            }
            .padding(10)
            SafariWebView(store: store)
        }
        .onReceive(store.$addressText) { addressDraft = $0 }
        .onAppear {
            if !didLoadInitial {
                didLoadInitial = true
                store.load("https://www.apple.com")
            }
        }
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }
}

// MARK: - Messages

/// A message the user actually wrote inside the VM (persisted).
struct VMMessage: Codable, Hashable, Identifiable {
    var id = UUID()
    let text: String
    let date: Date
    let outgoing: Bool
}

/// A conversation the user actually created inside the VM (persisted).
struct VMThread: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var messages: [VMMessage]
}

private enum MessageStore {
    static let key = "vm.messages.threads"

    static func load() -> [VMThread] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let threads = try? JSONDecoder().decode([VMThread].self, from: data) else { return [] }
        return threads
    }

    static func save(_ threads: [VMThread]) {
        if let data = try? JSONEncoder().encode(threads) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct MessagesAppView: View {
    @State private var threads: [VMThread] = []
    @State private var showNew = false
    @State private var newTitle = ""

    var body: some View {
        NavigationStack {
            List {
                if threads.isEmpty {
                    Text("暂无信息")
                        .foregroundStyle(.secondary)
                }
                ForEach(threads) { thread in
                    NavigationLink {
                        ThreadView(threadID: thread.id, threads: $threads)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(thread.title)
                            if let last = thread.messages.last {
                                Text(last.text)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNew = true } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .alert("新建信息", isPresented: $showNew) {
                TextField("收件人", text: $newTitle)
                Button("取消", role: .cancel) { newTitle = "" }
                Button("创建") {
                    let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return }
                    threads.append(VMThread(title: title, messages: []))
                    MessageStore.save(threads)
                    newTitle = ""
                }
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
            .onAppear { threads = MessageStore.load() }
        }
    }
}

private struct ThreadView: View {
    let threadID: UUID
    @Binding var threads: [VMThread]
    @State private var draft = ""

    private var thread: VMThread? { threads.first { $0.id == threadID } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let messages = thread?.messages, !messages.isEmpty {
                        ForEach(messages) { message in
                            HStack {
                                if message.outgoing { Spacer() }
                                Text(message.text)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        message.outgoing ? Color.blue : Color(.secondarySystemFill),
                                        in: RoundedRectangle(cornerRadius: 14)
                                    )
                                    .foregroundStyle(message.outgoing ? .white : .primary)
                                if !message.outgoing { Spacer() }
                            }
                        }
                    } else {
                        Text("还没有消息")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            HStack(spacing: 8) {
                TextField("信息", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("发送") { send() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .navigationTitle(thread?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].messages.append(VMMessage(text: text, date: Date(), outgoing: true))
        MessageStore.save(threads)
        draft = ""
    }
}

// MARK: - Music

/// A song name the user actually typed inside the VM (persisted).
/// Only the name is stored — there is no audio, and no fake catalog.
struct VMSong: Codable, Hashable, Identifiable {
    var id = UUID()
    let name: String
}

private enum MusicStore {
    static let key = "vm.music.songs"

    static func load() -> [VMSong] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let songs = try? JSONDecoder().decode([VMSong].self, from: data) else { return [] }
        return songs
    }

    static func save(_ songs: [VMSong]) {
        if let data = try? JSONEncoder().encode(songs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct MusicAppView: View {
    @State private var songs: [VMSong] = []
    @State private var showAdd = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                if songs.isEmpty {
                    Text("还没有歌曲")
                        .foregroundStyle(.secondary)
                }
                ForEach(songs.indices, id: \.self) { index in
                    NavigationLink(value: index) {
                        HStack {
                            Image(systemName: "music.note")
                                .foregroundStyle(.pink)
                            Text(songs[index].name)
                        }
                    }
                }
            }
            .navigationTitle("音乐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("添加歌曲", isPresented: $showAdd) {
                TextField("歌名", text: $newName)
                Button("取消", role: .cancel) { newName = "" }
                Button("添加") {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    songs.append(VMSong(name: name))
                    MusicStore.save(songs)
                    newName = ""
                }
            } message: {
                Text("输入歌名即可加入列表（仅显示名称，不播放音频）。")
            }
            .navigationDestination(for: Int.self) { index in
                if songs.indices.contains(index) {
                    PlayerView(songs: songs, index: index)
                }
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
            .onAppear { songs = MusicStore.load() }
        }
    }
}

/// Player page: play/pause drives a real elapsed timer; prev/next move
/// through the user's own songs. No audio is ever produced.
private struct PlayerView: View {
    let songs: [VMSong]
    @State private var index: Int
    @State private var playing = false
    @State private var startedAt: Date? = nil
    @State private var accumulated: TimeInterval = 0

    init(songs: [VMSong], index: Int) {
        self.songs = songs
        _index = State(initialValue: index)
    }

    private var current: VMSong? { songs.indices.contains(index) ? songs[index] : nil }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "music.note")
                    .font(.system(size: 72))
                    .foregroundStyle(.pink)
                Text(current?.name ?? "")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(VMTime.mmss(elapsed(now: context.date)))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
                HStack(spacing: 44) {
                    Button { skip(-1) } label: {
                        Image(systemName: "backward.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    Button { togglePlay(now: context.date) } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 40))
                    }
                    .buttonStyle(.plain)
                    Button { skip(1) } label: {
                        Image(systemName: "forward.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                }
                Text("仅显示播放状态，不播放音频。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
        }
        .navigationTitle("正在播放")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 28) }
    }

    private func elapsed(now: Date) -> TimeInterval {
        accumulated + (playing ? now.timeIntervalSince(startedAt ?? now) : 0)
    }

    private func togglePlay(now: Date) {
        if playing {
            accumulated = elapsed(now: now)
            startedAt = nil
            playing = false
        } else {
            startedAt = now
            playing = true
        }
    }

    private func skip(_ delta: Int) {
        guard !songs.isEmpty else { return }
        index = (index + delta + songs.count) % songs.count
        accumulated = 0
        startedAt = playing ? Date() : nil
    }
}
