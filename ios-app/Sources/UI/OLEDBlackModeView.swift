import SwiftUI
import UIKit

/// Pure #000000 OLED blackout mode that keeps the Metal GPU and UDP server alive
/// while turning off display pixels and protecting against OLED burn-in.
public struct OLEDBlackModeView: View {

    @ObservedObject var engine: TranslationEngine
    @Binding var isPresented: Bool

    @State private var dotOffset: CGSize = .zero
    @State private var showExitHint: Bool = true
    private let burnInTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    public init(engine: TranslationEngine, isPresented: Binding<Bool>) {
        self.engine = engine
        self._isPresented = isPresented
    }

    public var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 8, height: 8)
                        .opacity(0.45)

                    if engine.thermalState == .serious || engine.thermalState == .critical {
                        Text("تنبيه: حرارة الآيفون مرتفعة — انزع الغطاء أو افصل الشاحن")
                            .font(.caption2)
                            .foregroundColor(.orange.opacity(0.85))
                            .multilineTextAlignment(.center)
                    }
                }
                .offset(dotOffset)

                if showExitHint {
                    Text("3 ضغطات أو اسحب للأعلى للخروج من وضع التعتيم")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.28))
                        .transition(.opacity)
                }
            }
            .padding()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .contentShape(Rectangle())
        .onTapGesture(count: 3) {
            isPresented = false
        }
        .gesture(
            DragGesture(minimumDistance: 60)
                .onEnded { value in
                    if value.translation.height < -80 {
                        isPresented = false
                    }
                }
        )
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation(.easeOut(duration: 1.0)) {
                    showExitHint = false
                }
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(burnInTimer) { _ in
            withAnimation(.easeInOut(duration: 0.6)) {
                dotOffset = CGSize(
                    width: CGFloat.random(in: -90...90),
                    height: CGFloat.random(in: -180...180)
                )
            }
        }
    }

    private var statusDotColor: Color {
        if engine.thermalState == .serious || engine.thermalState == .critical {
            return .orange
        }
        if !engine.isServerRunning {
            return .red
        }
        switch engine.connectionMode {
        case .lan: return .green
        case .wifi: return .cyan
        case .unknown: return .yellow
        }
    }
}
