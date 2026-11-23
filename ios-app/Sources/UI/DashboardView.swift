import SwiftUI

public struct DashboardView: View {

    @ObservedObject var engine: TranslationEngine
    @State private var showBlackMode: Bool = false
    @State private var isRunningTest: Bool = false

    public init(engine: TranslationEngine) {
        self.engine = engine
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {

                    // 1. Thermal Warning Banner (if hot)
                    if engine.thermalState == .serious || engine.thermalState == .critical {
                        HStack(spacing: 10) {
                            Image(systemName: "thermometer.high")
                                .foregroundColor(.orange)
                            Text("حرارة الآيفون مرتفعة؛ يُفضّل نزع الغطاء أو إيقاف الشحن للحفاظ على أقصى سرعة.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // 2. Live Connection Badge Card (Ethernet LAN + Wi-Fi)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(connectionTitle, systemImage: connectionIcon)
                                .font(.headline)
                                .foregroundColor(connectionColor)
                            Spacer()
                            Text(engine.isServerRunning ? "شغّال" : "متوقف")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(engine.isServerRunning ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                                .foregroundColor(engine.isServerRunning ? .green : .red)
                                .clipShape(Capsule())
                        }

                        Divider()

                        HStack {
                            Text("عنوان السوني 5:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(engine.ps5IP)
                                .font(.caption.monospaced())
                        }

                        HStack {
                            Text("اللعبة النشطة:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(engine.activeTitleID)
                                .font(.caption.monospaced().bold())
                        }

                        HStack {
                            Text("النموذج الأوفلاين:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(engine.isLoadingModel ? "جاري التحميل..." : engine.loadedModelName)
                                .font(.caption)
                                .foregroundColor(engine.isModelLoaded ? .green : .orange)
                                .lineLimit(1)
                        }

                        if !engine.localInterfaces.isEmpty {
                            Divider()
                            HStack {
                                Text("عناوين الآيفون الحالية (سلك / واي فاي):")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    engine.refreshNetworkInterfaces()
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.caption)
                                }
                            }

                            ForEach(engine.localInterfaces) { iface in
                                HStack {
                                    Image(systemName: iface.isEthernet ? "cable.connector" : "wifi")
                                        .font(.caption)
                                        .foregroundColor(iface.isEthernet ? .green : .cyan)
                                    Text(iface.isEthernet ? "سلك Ethernet (\(iface.name))" : "واي فاي (\(iface.name))")
                                        .font(.caption)
                                    Spacer()
                                    Text(iface.ip)
                                        .font(.caption.monospaced().bold())
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // 3. Action Buttons (Server Toggle + OLED Black Mode)
                    HStack(spacing: 12) {
                        Button {
                            if engine.isServerRunning {
                                engine.stopServer()
                            } else {
                                engine.startServer()
                            }
                        } label: {
                            Label(
                                engine.isServerRunning ? "إيقاف السيرفر" : "تشغيل السيرفر",
                                systemImage: engine.isServerRunning ? "stop.circle.fill" : "play.circle.fill"
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(engine.isServerRunning ? .red : .green)

                        Button {
                            if !engine.isServerRunning {
                                engine.startServer()
                            }
                            showBlackMode = true
                        } label: {
                            Label("وضع الشاشة السوداء", systemImage: "moon.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                    }

                    // 4. Live Telemetry & Translation Preview Card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("مراقب الأداء اللحظي")
                                .font(.headline)
                            Spacer()
                            if !engine.lastOCRText.isEmpty {
                                Text(engine.lastWasCacheHit ? "من الكاش الفوري" : "ذكاء اصطناعي محلي")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(engine.lastWasCacheHit ? Color.mint.opacity(0.2) : Color.purple.opacity(0.2))
                                    .foregroundColor(engine.lastWasCacheHit ? .mint : .purple)
                                    .clipShape(Capsule())
                            }
                        }

                        HStack(spacing: 10) {
                            metricBox(title: "قراءة OCR", value: String(format: "%.0f ms", engine.lastOCRMs), color: .cyan)
                            metricBox(title: "أول كلمة TTFT", value: String(format: "%.0f ms", engine.lastTTFTMs), color: .green)
                            metricBox(title: "الإجمالي", value: String(format: "%.0f ms", engine.lastTotalMs), color: .orange)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("آخر نص إنجليزي:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(engine.lastOCRText.isEmpty ? "—" : engine.lastOCRText)
                                .font(.footnote.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color(.tertiarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("الترجمة العربية:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(engine.lastArabicText.isEmpty ? "—" : engine.lastArabicText)
                                .font(.body.bold())
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color.black.opacity(0.65))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // 5. One-Tap Offline Self-Test
                    Button {
                        isRunningTest = true
                        Task {
                            await engine.runOfflineSelfTest()
                            isRunningTest = false
                        }
                    } label: {
                        HStack {
                            if isRunningTest {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "bolt.shield.fill")
                            }
                            Text(isRunningTest ? "جاري اختبار المحرك الأوفلاين..." : "اختبار خط الترجمة أوفلاين (يعمل بوضع الطيران)")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunningTest)

                    Text(engine.statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("مترجم PS5 الفوري")
            .fullScreenCover(isPresented: $showBlackMode) {
                OLEDBlackModeView(engine: engine, isPresented: $showBlackMode)
            }
        }
    }

    private func metricBox(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.bold().monospacedDigit())
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var connectionTitle: String {
        switch engine.connectionMode {
        case .lan: return "متصل عبر السلك (Ethernet LAN)"
        case .wifi: return "متصل عبر الواي فاي (Wi-Fi)"
        case .unknown: return "بانتظار اتصال السوني 5"
        }
    }

    private var connectionIcon: String {
        switch engine.connectionMode {
        case .lan: return "cable.connector"
        case .wifi: return "wifi"
        case .unknown: return "antenna.radiowaves.left.and.right"
        }
    }

    private var connectionColor: Color {
        switch engine.connectionMode {
        case .lan: return .green
        case .wifi: return .cyan
        case .unknown: return .orange
        }
    }
}
