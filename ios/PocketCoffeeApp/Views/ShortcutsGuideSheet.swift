import SwiftUI
import PocketCoffeeCore
#if canImport(UIKit)
import UIKit
#endif

struct ShortcutsGuideSheet: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var feedbackText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroBanner
                    methodACard
                    methodBCard
                    safetyCard
                    quickToolsCard

                    if let feedbackText {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(CoffeeTheme.successGreen)
                            Text(feedbackText)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(CoffeeTheme.warmText)
                            Spacer()
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(CoffeeTheme.successGreen.opacity(0.14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(CoffeeTheme.successGreen.opacity(0.4), lineWidth: 1)
                                )
                        )
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .background(CoffeeTheme.espressoBg.ignoresSafeArea())
            .navigationTitle("iPhone 快捷指令自动化")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(CoffeeTheme.cremaLight)
                }
            }
        }
    }

    private var heroBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.badge.automatic.fill")
                .font(.title2)
                .foregroundStyle(CoffeeTheme.cremaAccent)
                .frame(width: 44, height: 44)
                .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("拍完即分析 · 通知直达报告")
                    .font(.headline)
                    .foregroundStyle(CoffeeTheme.warmText)
                Text("配合 iOS「快捷指令」，录完咖啡视频关闭相机后自动导入本机离线识别，完成后弹出通知，点击直达新报告。")
                    .font(.caption)
                    .foregroundStyle(CoffeeTheme.mutedText)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(cardBackground)
    }

    private var methodACard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("方式 A（推荐）：关闭「相机」全自动触发", systemImage: "camera.aperture")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(CoffeeTheme.cremaLight)
                Spacer()
                Text("最省心")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(CoffeeTheme.cremaAccent.opacity(0.2), in: Capsule())
                    .foregroundStyle(CoffeeTheme.cremaAccent)
            }

            VStack(alignment: .leading, spacing: 8) {
                guideStep(1, "打开系统「快捷指令」App，切换到底部「自动化」标签，点击右上角「+」。")
                guideStep(2, "下滑选择「App」，App 选「相机」，勾选「已关闭」（取消勾选已打开）。")
                guideStep(3, "选择「立即运行」，关闭「运行时通知」，点击「下一步」。")
                guideStep(4, "点击「新建空白自动化」→ 搜索「萃镜」→ 选择「导入最新咖啡视频并生成报告」。")
                guideStep(5, "可选优化：点开该操作，把「运行时显示」关掉，切出相机后更丝滑无额外确认弹窗。")
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var methodBCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("方式 B：操作按钮 / Siri 一键触发", systemImage: "hand.tap.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(CoffeeTheme.cremaLight)

            VStack(alignment: .leading, spacing: 8) {
                guideStep(1, "iPhone 15 Pro / 16 Pro：前往系统「设置 → 操作按钮 → 快捷指令」，绑定「导入最新咖啡视频并生成报告」。")
                guideStep(2, "Siri 语音：录完视频后直接说「嘿 Siri，导入最新咖啡视频」即可自动触发。")
                guideStep(3, "URL 深链备用：在任意快捷指令中添加「打开 URL」并填入 brewlens://import-latest。")
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("防误触发与通知说明", systemImage: "shield.lefthalf.filled")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(CoffeeTheme.successGreen)

            bulletRow("自动去重：同一段视频不会重复导入，关闭相机时若没拍新视频会自动跳过。")
            bulletRow("非咖啡拦截：随手拍的日常非咖啡视频会被端侧守门员自动拦截，不会污染报告库。")
            bulletRow("通知直达：分析完成立刻弹出本地通知（前台/后台均支持），点击横幅直接打开刚刚生成的报告详情。")
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CoffeeTheme.successGreen.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(CoffeeTheme.successGreen.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private var quickToolsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快捷操作与自检")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(CoffeeTheme.cremaLight)

            Button {
                if let url = URL(string: "shortcuts://") {
                    openURL(url)
                }
            } label: {
                Label("打开系统「快捷指令」App 去配置", systemImage: "arrow.up.forward.app.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(CoffeeTheme.cremaAccent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(CoffeeTheme.espressoBg)
            }

            HStack(spacing: 10) {
                Button {
                    dismiss()
                    Task {
                        await viewModel.importLatestPhotoVideoAndGenerate(skipIfAlreadyImported: false)
                    }
                } label: {
                    Label("立即试跑最新视频", systemImage: "play.circle.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(CoffeeTheme.cremaAccent.opacity(0.6), lineWidth: 1)
                        )
                        .foregroundStyle(CoffeeTheme.cremaLight)
                }
                .disabled(viewModel.isBusy)

                Button {
                    Task {
                        let msg = await AppNotificationManager.shared.sendTestNotification(targetRecord: viewModel.records.first)
                        feedbackText = msg
                    }
                } label: {
                    Label("发一条测试通知", systemImage: "bell.badge.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
                        )
                        .foregroundStyle(CoffeeTheme.warmText)
                }
            }

            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = "brewlens://import-latest"
                #endif
                feedbackText = "已复制深链：brewlens://import-latest"
            } label: {
                Label("复制备用触发深链 (brewlens://import-latest)", systemImage: "doc.on.doc")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(CoffeeTheme.cardElevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(CoffeeTheme.mutedText)
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private func guideStep(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.caption2.bold().monospacedDigit())
                .foregroundStyle(CoffeeTheme.espressoBg)
                .frame(width: 20, height: 20)
                .background(CoffeeTheme.cremaAccent, in: Circle())
                .padding(.top, 1)

            Text(text)
                .font(.caption)
                .foregroundStyle(CoffeeTheme.warmText.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(CoffeeTheme.successGreen)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
                .foregroundStyle(CoffeeTheme.warmText.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(CoffeeTheme.cardSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
            )
    }
}
