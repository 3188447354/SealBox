//
//  LCDesktopWallpaper.swift
//  LiveContainerSwiftUI
//
//  Desktop wallpaper + theme (SealBox).
//
//  Wallpaper: the top-right "···" menu (edit mode only) has a "壁纸"
//  entry that opens the system photo picker; the picked image is applied
//  immediately, as-is — there is no edit page and no crop / zoom /
//  brightness / blur controls (MJ: no editing). The wallpaper is an
//  in-app background only -- it never touches the system wallpaper.
//  Display follows a real phone home screen: the image is centred and
//  aspect-filled to the screen, whatever its shape (landscape, portrait
//  or square) and whatever the device size — no stretching, no blank
//  edges, nothing for the user to tune.
//  Default wallpaper: the bundled "DefaultWallpaper" image (MJ's rainy
//  selfie, 1008x2304) in Assets.xcassets. First launch — and "恢复默认
//  壁纸" — show that image. It lives in the app bundle, so a custom
//  wallpaper can never overwrite it.
//  Theme: system / dark / light, chosen in the "···" menu. Wallpaper
//  and theme are stored separately: changing one never resets the other.
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Theme (dark / light / follow system)

/// Desktop colour theme. Stored separately from the wallpaper: changing
/// the wallpaper never resets the theme, and changing the theme never
/// drops the wallpaper.
enum LCDesktopTheme: String, CaseIterable {
    case system
    case dark
    case light

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .dark: "深色"
        case .light: "浅色"
        }
    }

    /// nil = follow the system. Applied with .preferredColorScheme().
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }

    /// Icon-name colour for this theme. The grid cell always adds a dark
    /// shadow on top (see LCDesktopGridCell), so a light theme on a dark
    /// wallpaper stays readable.
    var nameColor: Color {
        switch self {
        case .system: .primary
        case .dark: .white
        case .light: .black
        }
    }

    /// Extra dimming applied over the wallpaper for this theme.
    /// Dark theme darkens the background, light theme lightens it,
    /// system leaves the wallpaper untouched.
    var wallpaperDim: Color {
        switch self {
        case .system: .clear
        case .dark: Color.black.opacity(0.35)
        case .light: Color.white.opacity(0.20)
        }
    }
}

// MARK: - Wallpaper store (load / save / reset)

/// Owns the desktop wallpaper image.
///
/// Storage: a single file, the custom wallpaper only:
///   App Group container / SealBoxWallpaper/wallpaper.jpg
/// If the App Group container is unavailable (e.g. entitlements are
/// wrong), the same file is used under the app's Documents directory
/// instead. No settings file: there is nothing to tune (no crop / zoom /
/// brightness / blur), so only the image itself is stored. An old
/// wallpaper.json left by an earlier build is deleted on reset; it is
/// never read.
/// The default wallpaper is NOT stored here: it is the bundled
/// "DefaultWallpaper" image in Assets.xcassets, read straight from the
/// app bundle, so a custom wallpaper can never overwrite it.
/// The picked image is downscaled to at most 2048px on the long edge and
/// stored as JPEG (quality 0.85) so the file stays small; the original
/// photo is never kept.
final class LCDesktopWallpaperStore: ObservableObject {
    @Published private(set) var image: UIImage?
    /// True only when the user has picked a custom wallpaper (a stored
    /// file exists). False means the bundled default is showing.
    @Published private(set) var hasCustomWallpaper: Bool = false

    static let folderName = "SealBoxWallpaper"
    static let imageFileName = "wallpaper.jpg"
    /// Legacy settings file from the removed edit page. Never written
    /// anymore; deleted on reset so it cannot linger.
    static let legacySettingsFileName = "wallpaper.json"
    static let maxDimension: CGFloat = 2048

    /// The bundled default wallpaper (MJ's rainy selfie, in
    /// Assets.xcassets / DefaultWallpaper.imageset). UIImage(named:)
    /// reads the main bundle's asset catalog.
    static var bundledDefaultImage: UIImage? {
        UIImage(named: "DefaultWallpaper")
    }

    /// Directory used for the wallpaper file. App Group first,
    /// Documents as fallback. Exposed for the Settings "reset" helper.
    static var wallpaperDirectory: URL {
        let base: URL
        if let groupURL = LCSharedUtils.appGroupPath() {
            base = groupURL
        } else {
            base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Deletes the stored custom wallpaper without needing an instance
    /// (used by the Settings "外观" section). The bundled default is
    /// untouched: it lives in the app bundle, not in this directory.
    static func resetStoredWallpaper() {
        let dir = wallpaperDirectory
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(imageFileName))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(legacySettingsFileName))
    }

    init() {
        load()
    }

    /// Loads the stored custom wallpaper, if any. No custom wallpaper
    /// means the bundled default image is shown instead — `image` is
    /// never nil after this (unless the bundled asset itself is
    /// missing, in which case the desktop has no background at all).
    func load() {
        let dir = Self.wallpaperDirectory
        if let data = try? Data(contentsOf: dir.appendingPathComponent(Self.imageFileName)),
           let loaded = UIImage(data: data) {
            image = loaded
            hasCustomWallpaper = true
        } else {
            image = Self.bundledDefaultImage
            hasCustomWallpaper = false
        }
    }

    /// Applies a new wallpaper: writes the (downscaled) image, then
    /// publishes it. The picked image is used as-is — no edit step.
    func apply(image: UIImage) {
        guard let data = Self.jpegData(for: image) else { return }
        let dir = Self.wallpaperDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent(Self.imageFileName), options: .atomic)
        self.image = image
        hasCustomWallpaper = true
    }

    /// Restores the default wallpaper: deletes the stored custom file
    /// (and any legacy settings file) and goes back to the bundled
    /// default image.
    func resetToDefault() {
        Self.resetStoredWallpaper()
        image = Self.bundledDefaultImage
        hasCustomWallpaper = false
    }

    /// Downscales an image to at most `maxDimension` on the long edge
    /// and returns JPEG data (quality 0.85). Returns nil for an empty
    /// image.
    static func jpegData(for image: UIImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}

// MARK: - System photo picker (PHPickerViewController)
//
// SwiftUI's PhotosPicker needs iOS 16, but the app's deployment target
// is iOS 15. PHPickerViewController is the same system photo picker
// underneath (single image, no full-library permission needed) and works
// from iOS 14, so it is used here instead of a file picker.

struct LCPhotoPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onPick: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented, onPick: onPick)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        @Binding var isPresented: Bool
        var onPick: (UIImage) -> Void

        init(isPresented: Binding<Bool>, onPick: @escaping (UIImage) -> Void) {
            _isPresented = isPresented
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            isPresented = false
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async {
                    self.onPick(image)
                }
            }
        }
    }
}
