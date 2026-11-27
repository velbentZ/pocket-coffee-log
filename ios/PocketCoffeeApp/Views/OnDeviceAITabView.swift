import SwiftUI
import PocketCoffeeCore

struct OnDeviceAITabView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var showShortcutsGuide: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CoffeeTabHeader(
                    title: "端侧 AI 与隐私",
                    subtitle: "本地离线推理 · 零云端上传",
                    subtitleIcon: "lock.shield.fill",
                    subtitleIconColor: CoffeeTheme.successGreen
                ) {
                    Button {
                        viewModel.refreshCapabilities()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption.weight(.bold))
                            Text("重新检测")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(CoffeeTheme.cardElevated, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(CoffeeTheme.cremaAccent.opacity(0.45), lineWidth: 1)
                        )
                        .foregroundStyle(CoffeeTheme.cremaLight)
                    }
                    .buttonStyle(.plain)
                }

                ScrollView {
                    VStack(spacing: 16) {
                        activeAdvisorCard
                        shortcutsAutomationCard
                        capabilitiesListCard
                        privacyGuaranteeCard
                        macLanSyncCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .background(CoffeeTheme.espressoBg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showShortcutsGuide) {
                ShortcutsGuideSheet()
                    .environmentObject(viewModel)
            }
        }
    }

    private var activeAdvisorCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "cpu.fill")
                    .font(.title2)
                    .foregroundStyle(CoffeeTheme.cremaAccent)
                    .frame(width: 44, height: 44)
                    .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("当前端侧诊断引擎")
                        .font(.caption)
                        .foregroundStyle(CoffeeTheme.mutedText)
                    Text(viewModel.capabilities.activeAdvisorName)
                        .font(.headline)
                        .foregroundStyle(CoffeeTheme.warmText)
                }
                Spacer()
            }

            Text(viewModel.capabilities.summaryText)
                .font(.subheadline)
                .foregroundStyle(CoffeeTheme.cremaLight)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(cardBackground)
    }

    private var shortcutsAutomationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.badge.automatic.fill")
                    .font(.title2)
                    .foregroundStyle(CoffeeTheme.cremaAccent)
                    .frame(width: 44, height: 44)
                    .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("iPhone 快捷指令自动导入")
                        .font(.headline)
                        .foregroundStyle(CoffeeTheme.warmText)
                    Text("录完视频关闭相机自动识别，完成通知点击直达报告")
                        .font(.caption)
                        .foregroundStyle(CoffeeTheme.mutedText)
                }
                Spacer()
            }

            Button {
                showShortcutsGuide = true
            } label: {
                Label("查看配置指引与一键测试", systemImage: "list.bullet.rectangle.portrait")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(CoffeeTheme.cremaAccent.opacity(0.6), lineWidth: 1)
                    )
                    .foregroundStyle(CoffeeTheme.cremaLight)
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private var capabilitiesListCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple 原生端侧能力检测")
                .font(.headline)
                .foregroundStyle(CoffeeTheme.cremaLight)

            capabilityRow(
                icon: "waveform",
                title: "Apple On-Device Speech",
                subtitle: "离线中文/中英混合语音转文字，无需联网",
                available: viewModel.capabilities.onDeviceSpeechAvailable,
                fallbackText: "需真机并开启离线听写"
            )

            capabilityRow(
                icon: "text.viewfinder",
                title: "Apple Vision OCR",
                subtitle: "视频关键帧电子秤/压力表/豆袋文字识别",
                available: viewModel.capabilities.visionOCRAvailable,
                fallbackText: "不可用"
            )

            capabilityRow(
                icon: "sparkles",
                title: "Apple FoundationModels",
                subtitle: "iOS 26+ Apple Intelligence 端侧大模型润色与诊断",
                available: viewModel.capabilities.appleFoundationModelsAvailable,
                fallbackText: "已无缝启用离线咖啡师规则引擎"
            )
        }
        .padding(14)
        .background(cardBackground)
    }

    private func capabilityRow(
        icon: String,
        title: String,
        subtitle: String,
        available: Bool,
        fallbackText: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(available ? CoffeeTheme.successGreen : CoffeeTheme.warningAmber)
                .frame(width: 30, height: 30)
                .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CoffeeTheme.warmText)
                    Spacer()
                    Text(available ? "已就绪" : "回退模式")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (available ? CoffeeTheme.successGreen : CoffeeTheme.warningAmber).opacity(0.18),
                            in: Capsule()
                        )
                        .foregroundStyle(available ? CoffeeTheme.successGreen : CoffeeTheme.warningAmber)
                }
                Text(available ? subtitle : fallbackText)
                    .font(.caption)
                    .foregroundStyle(CoffeeTheme.mutedText)
            }
        }
        .padding(10)
        .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var privacyGuaranteeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("100% 离线 · 零云端隐私保障", systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(CoffeeTheme.successGreen)

            VStack(alignment: .leading, spacing: 6) {
                privacyBullet("零云端 API 调用：视频抽帧、Speech 语音转写、Vision OCR、咖啡师诊断全部在 iPhone 本机完成。")
                privacyBullet("零账号登录与零遥测：所有冲煮报告、豆库余量与设备档案均以 JSON 存储在本地沙盒目录。")
                privacyBullet("飞行模式可用：在无网环境下同样可以完整拍摄、识别、分析与管理咖啡豆。")
            }
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

    private func privacyBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(CoffeeTheme.successGreen)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
                .foregroundStyle(CoffeeTheme.warmText.opacity(0.9))
        }
    }

    private var macLanSyncCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("同步至 Mac 局域网中枢 (:8788)", systemImage: "laptopcomputer.and.iphone")
                .font(.headline)
                .foregroundStyle(CoffeeTheme.cremaLight)

            Text("可选功能：开启后，端侧生成新报告或设备建档时，会将结构化参数同步推送至局域网内的 Mac 萃镜 (BrewLens) 桌面中枢（POST /api/ingest/process）。")
                .font(.caption)
                .foregroundStyle(CoffeeTheme.mutedText)

            Toggle(isOn: $viewModel.lanSyncEnabled) {
                Text("启用局域网自动同步")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CoffeeTheme.warmText)
            }
            .tint(CoffeeTheme.cremaAccent)

            VStack(alignment: .leading, spacing: 4) {
                Text("Mac 中枢局域网地址")
                    .font(.caption)
                    .foregroundStyle(CoffeeTheme.mutedText)
                TextField("http://192.168.1.100:8788", text: $viewModel.macHubBaseURL)
                    .font(.subheadline.monospaced())
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(CoffeeTheme.cardElevated)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(CoffeeTheme.cardBorder, lineWidth: 1)
                            )
                    )
            }

            HStack(spacing: 10) {
                Button {
                    Task { await viewModel.testMacHubConnection() }
                } label: {
                    HStack(spacing: 6) {
                        if viewModel.isSyncingToMac {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "wifi")
                        }
                        Text("测试 Mac 中枢连接")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(CoffeeTheme.cardElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(CoffeeTheme.cremaAccent.opacity(0.6), lineWidth: 1)
                    )
                    .foregroundStyle(CoffeeTheme.cremaLight)
                }
                .disabled(viewModel.isSyncingToMac)
            }

            if let summary = viewModel.lastSyncSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(CoffeeTheme.mutedText)
            }
        }
        .padding(14)
        .background(cardBackground)
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
