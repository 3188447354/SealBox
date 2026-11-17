import SwiftUI

// Static home screen. Everything on this screen is a plain, inert view:
// no Button, no onTapGesture, no NavigationLink, no state. Taps do nothing.
struct HomeScreenView: View {
    var body: some View {
        ZStack {
            // Wallpaper: iOS-style gradient with soft color blobs.
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.25, blue: 0.85),
                    Color(red: 0.35, green: 0.25, blue: 0.75),
                    Color(red: 0.75, green: 0.30, blue: 0.55),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            Circle()
                .fill(Color(red: 0.15, green: 0.65, blue: 0.95).opacity(0.55))
                .frame(width: 340, height: 340)
                .blur(radius: 60)
                .offset(x: -110, y: -260)
            Circle()
                .fill(Color(red: 0.95, green: 0.45, blue: 0.65).opacity(0.45))
                .frame(width: 300, height: 300)
                .blur(radius: 70)
                .offset(x: 130, y: 140)

            VStack(spacing: 0) {
                // Clear the real system status bar / Dynamic Island.
                Spacer()
                    .frame(height: 54)

                // First row: the three built-in apps.
                HStack(alignment: .top, spacing: 26) {
                    HomeAppIcon(
                        label: "设置",
                        symbol: "gearshape.fill",
                        gradient: [Color(red: 0.56, green: 0.56, blue: 0.58),
                                   Color(red: 0.39, green: 0.39, blue: 0.40)]
                    )
                    HomeAppIcon(
                        label: "软件源",
                        symbol: "arrow.down.to.line",
                        gradient: [Color(red: 0.04, green: 0.52, blue: 1.0),
                                   Color(red: 0.19, green: 0.69, blue: 1.0)]
                    )
                    HomeAppIcon(
                        label: "插件",
                        symbol: "puzzlepiece.extension.fill",
                        gradient: [Color(red: 0.69, green: 0.32, blue: 0.87),
                                   Color(red: 0.49, green: 0.17, blue: 0.91)]
                    )
                    Spacer()
                }
                .padding(.horizontal, 26)

                // Page dots.
                HStack(spacing: 8) {
                    Circle().fill(Color.white).frame(width: 7, height: 7)
                    Circle().fill(Color.white.opacity(0.4)).frame(width: 7, height: 7)
                }
                .padding(.top, 26)

                Spacer()

                // Dock: four pure-visual system icons.
                HStack(spacing: 0) {
                    DockIcon(symbol: "phone.fill",
                             gradient: [Color(red: 0.20, green: 0.78, blue: 0.35),
                                        Color(red: 0.20, green: 0.78, blue: 0.35)])
                    Spacer()
                    DockIcon(symbol: "safari",
                             gradient: [Color.white, Color.white],
                             symbolColor: Color(red: 0.04, green: 0.52, blue: 1.0))
                    Spacer()
                    DockIcon(symbol: "message.fill",
                             gradient: [Color(red: 0.19, green: 0.82, blue: 0.35),
                                        Color(red: 0.19, green: 0.82, blue: 0.35)])
                    Spacer()
                    DockIcon(symbol: "music.note",
                             gradient: [Color(red: 0.99, green: 0.23, blue: 0.42),
                                        Color(red: 0.98, green: 0.18, blue: 0.28)])
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }
}

private struct HomeAppIcon: View {
    let label: String
    let symbol: String
    let gradient: [Color]

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom))
                    .frame(width: 64, height: 64)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(.white)
            }
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
        }
    }
}

private struct DockIcon: View {
    let symbol: String
    let gradient: [Color]
    var symbolColor: Color = .white

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15)
                .fill(LinearGradient(colors: gradient, startPoint: .top, endPoint: .bottom))
                .frame(width: 60, height: 60)
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(symbolColor)
        }
    }
}
