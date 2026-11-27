import SwiftUI
import AppKit
import QuartzCore
import DiskGuardCore

struct DesktopPetView: View {
    @ObservedObject var viewModel: AppViewModel
    let onRestoreMainWindow: () -> Void
    @State private var isHovered = false

    private var petSize: CGFloat {
        viewModel.petDisplaySize.pointSize
    }

    private var panelWidth: CGFloat {
        max(196, petSize + 64)
    }

    private var headroomHeight: CGFloat {
        48
    }

    private var memory: MemoryStats { viewModel.systemSnapshot.memory }
    private var cpu: CPUStats { viewModel.systemSnapshot.cpu }
    private var health: MacHealthStats { viewModel.systemSnapshot.health }
    private var mood: PetMood { viewModel.currentPetMood }

    private var pressureColor: Color {
        switch memory.pressure {
        case .normal: return Color(red: 0.22, green: 0.85, blue: 0.56)
        case .warning: return Color(red: 0.98, green: 0.65, blue: 0.20)
        case .critical: return Color(red: 0.96, green: 0.34, blue: 0.34)
        }
    }

    private var cpuColor: Color {
        if cpu.totalUsage >= 0.8 { return Color(red: 0.96, green: 0.42, blue: 0.30) }
        if cpu.totalUsage >= 0.5 { return Color(red: 0.98, green: 0.68, blue: 0.22) }
        return Color(red: 0.32, green: 0.82, blue: 0.92)
    }

    var body: some View {
        let pack = viewModel.activePetPack
        let petImage = pack.flatMap { viewModel.petAssetStore.cgImage(for: $0, mood: mood) }

        VStack(spacing: 0) {
            topOverlaySlot
                .frame(height: headroomHeight, alignment: .bottom)
                .padding(.bottom, 2)

            ZStack(alignment: .topTrailing) {
                if let petImage {
                    BreathingPetLayerView(cgImage: petImage, mood: mood, size: petSize)
                        .frame(width: petSize, height: petSize)
                } else {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: petSize * 0.45))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: petSize, height: petSize)
                }

                ambientMoodSticker
                    .offset(x: 6, y: 2)
            }
            .frame(width: petSize, height: petSize)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                onRestoreMainWindow()
            }
            .onTapGesture(count: 1) {
                viewModel.petInteractionTap()
            }
        }
        .frame(width: panelWidth, height: petSize + headroomHeight + 2)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var topOverlaySlot: some View {
        if isHovered {
            hoverTelemetryPill
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
        } else if let bubble = viewModel.petBubbleText {
            speechBubble(bubble)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            Color.clear
        }
    }

    private var hoverTelemetryPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(pressureColor)
                .frame(width: 6.5, height: 6.5)

            Text("内存 \(Int((memory.usedRatio * 100).rounded()))%")
                .foregroundStyle(.white.opacity(0.95))

            Text("·")
                .foregroundStyle(.white.opacity(0.45))

            Text(String(format: "CPU %.0f%%", cpu.totalUsage * 100))
                .foregroundStyle(cpuColor)

            if let badge = health.vpn.shortBadgeText {
                Text("·")
                    .foregroundStyle(.white.opacity(0.45))
                Text(badge)
                    .foregroundStyle(Color(red: 0.35, green: 0.88, blue: 0.68))
            }

            Button {
                viewModel.setFloatingHUDMode(.pill)
            } label: {
                Image(systemName: "capsule.portrait")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 17, height: 17)
                    .background(Color.white.opacity(0.16))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("切换为迷你胶囊")
        }
        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.62))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 4, x: 0, y: 2)
    }

    private func speechBubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.96))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.64))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.24), radius: 4, x: 0, y: 2)
    }

    @ViewBuilder
    private var ambientMoodSticker: some View {
        switch mood {
        case .idle:
            EmptyView()
        case .happy:
            Image(systemName: "heart.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.54))
                .shadow(color: .black.opacity(0.32), radius: 2, x: 0, y: 1)
        case .busy:
            Image(systemName: "drop.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(red: 0.42, green: 0.82, blue: 1.0))
                .shadow(color: .black.opacity(0.32), radius: 2, x: 0, y: 1)
        case .stressed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(red: 1.0, green: 0.58, blue: 0.24))
                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
        case .sleepy:
            Text("Zzz")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.78, green: 0.88, blue: 1.0))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.45))
                .clipShape(Capsule())
        }
    }
}

struct BreathingPetLayerView: NSViewRepresentable {
    let cgImage: CGImage
    let mood: PetMood
    let size: CGFloat

    final class Coordinator {
        weak var petLayer: CALayer?
        var lastCGImage: CGImage?
        var lastMood: PetMood?
        var lastSize: CGFloat = 0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PetStageNSView {
        let view = PetStageNSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        let layer = CALayer()
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.0)
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.26
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: -2)
        view.layer?.addSublayer(layer)
        view.petLayer = layer

        context.coordinator.petLayer = layer
        syncLayer(in: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: PetStageNSView, context: Context) {
        syncLayer(in: nsView, coordinator: context.coordinator)
    }

    private func syncLayer(in view: PetStageNSView, coordinator: Coordinator) {
        guard let layer = coordinator.petLayer else { return }

        if coordinator.lastSize != size {
            coordinator.lastSize = size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            layer.position = CGPoint(x: size * 0.5, y: 0)
            CATransaction.commit()
        }

        if coordinator.lastCGImage !== cgImage {
            coordinator.lastCGImage = cgImage
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.22)
            layer.contents = cgImage
            CATransaction.commit()
        }

        if coordinator.lastMood != mood {
            coordinator.lastMood = mood
            applyBreathingAnimations(to: layer, mood: mood)
        }
    }

    private func applyBreathingAnimations(to layer: CALayer, mood: PetMood) {
        layer.removeAnimation(forKey: "pet.breatheScale")
        layer.removeAnimation(forKey: "pet.breatheBounce")
        layer.removeAnimation(forKey: "pet.tilt")

        let duration: CFTimeInterval
        let scaleYTo: CGFloat
        let bounceY: CGFloat
        var tiltAngle: CGFloat = 0

        switch mood {
        case .idle:
            duration = 2.8
            scaleYTo = 1.030
            bounceY = 1.4
        case .happy:
            duration = 0.62
            scaleYTo = 1.055
            bounceY = 5.0
        case .busy:
            duration = 0.85
            scaleYTo = 1.040
            bounceY = 2.6
        case .stressed:
            duration = 0.52
            scaleYTo = 1.022
            bounceY = 1.2
            tiltAngle = 0.032
        case .sleepy:
            duration = 4.2
            scaleYTo = 1.020
            bounceY = 0.7
        }

        let scaleAnim = CABasicAnimation(keyPath: "transform.scale.y")
        scaleAnim.fromValue = 1.0
        scaleAnim.toValue = scaleYTo
        scaleAnim.duration = duration
        scaleAnim.autoreverses = true
        scaleAnim.repeatCount = .infinity
        scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scaleAnim.isRemovedOnCompletion = false
        layer.add(scaleAnim, forKey: "pet.breatheScale")

        let posAnim = CABasicAnimation(keyPath: "position.y")
        posAnim.fromValue = 0.0
        posAnim.toValue = bounceY
        posAnim.duration = duration
        posAnim.autoreverses = true
        posAnim.repeatCount = .infinity
        posAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        posAnim.isRemovedOnCompletion = false
        layer.add(posAnim, forKey: "pet.breatheBounce")

        if tiltAngle > 0 {
            let tiltAnim = CABasicAnimation(keyPath: "transform.rotation.z")
            tiltAnim.fromValue = -tiltAngle
            tiltAnim.toValue = tiltAngle
            tiltAnim.duration = duration * 0.9
            tiltAnim.autoreverses = true
            tiltAnim.repeatCount = .infinity
            tiltAnim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            tiltAnim.isRemovedOnCompletion = false
            layer.add(tiltAnim, forKey: "pet.tilt")
        }
    }
}

final class PetStageNSView: NSView {
    weak var petLayer: CALayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard let petLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        petLayer.bounds = bounds
        petLayer.position = CGPoint(x: bounds.midX, y: 0)
        CATransaction.commit()
    }
}
