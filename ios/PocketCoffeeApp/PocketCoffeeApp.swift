import SwiftUI
import PocketCoffeeCore

enum CoffeeTheme {
    static let cremaAccent = Color(red: 0.85, green: 0.59, blue: 0.37)
    static let cremaLight = Color(red: 0.95, green: 0.80, blue: 0.64)
    static let espressoBg = Color(red: 0.08, green: 0.06, blue: 0.05)
    static let cardSurface = Color(red: 0.14, green: 0.11, blue: 0.09)
    static let cardElevated = Color(red: 0.19, green: 0.15, blue: 0.12)
    static let cardBorder = Color(red: 0.32, green: 0.24, blue: 0.19).opacity(0.65)
    static let warmText = Color(red: 0.97, green: 0.94, blue: 0.90)
    static let mutedText = Color(red: 0.72, green: 0.65, blue: 0.58)
    static let successGreen = Color(red: 0.34, green: 0.76, blue: 0.52)
    static let warningAmber = Color(red: 0.95, green: 0.68, blue: 0.25)
    static let equipmentBlue = Color(red: 0.44, green: 0.68, blue: 0.95)
    static let dangerRed = Color(red: 0.90, green: 0.35, blue: 0.32)
}

/// Unified top header used identically across all 4 main tabs so every screen
/// shares the exact same breathing room below the Dynamic Island / safe area
/// and aligns any right-side action pill on the same baseline as the title.
struct CoffeeTabHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let subtitleIcon: String?
    let subtitleIconColor: Color
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String,
        subtitleIcon: String? = nil,
        subtitleIconColor: Color = CoffeeTheme.cremaAccent,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleIcon = subtitleIcon
        self.subtitleIconColor = subtitleIconColor
        self.trailing = trailing
    }

    init(
        title: String,
        subtitle: String,
        subtitleIcon: String? = nil,
        subtitleIconColor: Color = CoffeeTheme.cremaAccent
    ) where Trailing == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.subtitleIcon = subtitleIcon
        self.subtitleIconColor = subtitleIconColor
        self.trailing = { EmptyView() }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(CoffeeTheme.warmText)
                HStack(spacing: 5) {
                    if let subtitleIcon {
                        Image(systemName: subtitleIcon)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(subtitleIconColor)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(CoffeeTheme.mutedText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}

@main
struct PocketCoffeeApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
                .tint(CoffeeTheme.cremaAccent)
                .onAppear {
                    AppNotificationManager.shared.configure { recordID in
                        viewModel.openReport(id: recordID)
                    }
                }
                .onOpenURL { url in
                    viewModel.handleDeepLink(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: .pocketCoffeeTriggerImportLatest)) { _ in
                    Task {
                        await viewModel.importLatestPhotoVideoAndGenerate(skipIfAlreadyImported: true)
                    }
                }
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $viewModel.selectedTab) {
                IngestTabView()
                    .tabItem {
                        Label("拍摄/导入", systemImage: "camera.viewfinder")
                    }
                    .tag(AppTab.ingest)

                ReportsTabView()
                    .tabItem {
                        Label("咖啡报告", systemImage: "cup.and.saucer.fill")
                    }
                    .tag(AppTab.reports)

                BeansEquipmentTabView()
                    .tabItem {
                        Label("豆库&设备", systemImage: "shippingbox.fill")
                    }
                    .tag(AppTab.beansEquipment)

                OnDeviceAITabView()
                    .tabItem {
                        Label("端侧AI", systemImage: "cpu.fill")
                    }
                    .tag(AppTab.onDeviceAI)
            }
            .background(CoffeeTheme.espressoBg.ignoresSafeArea())

            if let banner = viewModel.errorMessage ?? viewModel.statusMessage {
                let isError = viewModel.errorMessage != nil
                HStack(spacing: 10) {
                    Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isError ? CoffeeTheme.dangerRed : CoffeeTheme.successGreen)
                    Text(banner)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(CoffeeTheme.warmText)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button {
                        viewModel.clearMessages()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .foregroundStyle(CoffeeTheme.mutedText)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(CoffeeTheme.cardElevated)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(isError ? CoffeeTheme.dangerRed.opacity(0.6) : CoffeeTheme.cremaAccent.opacity(0.5), lineWidth: 1)
                        )
                )
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.statusMessage)
        .animation(.easeInOut(duration: 0.25), value: viewModel.errorMessage)
    }
}
