import SwiftUI

struct VoiceSessionView: View {
    let server: URL
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: VoiceSessionViewModel
    @State private var pulseOpacity: Double = 0
    @State private var pulseScale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(server: URL) {
        self.server = server
        _viewModel = State(initialValue: VoiceSessionViewModel(server: server))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 16)
                    .padding(.horizontal, 20)

                transcriptView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomSection
                    .padding(.bottom, 52)
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { viewModel.close() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                viewModel.close()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Voice")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            Spacer()

            Color.clear.frame(width: 36, height: 36)
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptView: some View {
        if viewModel.turns.isEmpty && viewModel.currentResponseText.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(viewModel.turns) { turn in
                            VoiceTurnBubbleView(turn: turn)
                        }

                        if !viewModel.currentResponseText.isEmpty {
                            streamingBubble
                                .id("streaming")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .onChange(of: viewModel.currentResponseText) {
                    withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
                }
                .onChange(of: viewModel.turns.count) {
                    withAnimation { proxy.scrollTo(viewModel.turns.last?.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.18))

            Text("Tap the mic and start talking")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var streamingBubble: some View {
        HStack {
            Text(viewModel.currentResponseText)
                .font(.body)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Spacer(minLength: 48)
        }
    }

    // MARK: - Bottom controls

    private var bottomSection: some View {
        VStack(spacing: 20) {
            liveTranscriptLabel
            statusLabel
            micButton
        }
    }

    @ViewBuilder
    private var liveTranscriptLabel: some View {
        if !viewModel.liveTranscript.isEmpty {
            Text(viewModel.liveTranscript)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 32)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: viewModel.liveTranscript)
        } else {
            Color.clear.frame(height: 20)
        }
    }

    private var statusLabel: some View {
        Text(viewModel.phase.statusLabel)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(statusLabelColor)
            .animation(.easeInOut(duration: 0.2), value: viewModel.phase.statusLabel)
    }

    private var statusLabelColor: Color {
        switch viewModel.phase {
        case .error: return .red.opacity(0.8)
        default: return .white.opacity(0.45)
        }
    }

    // MARK: - Mic button

    private var micButton: some View {
        Button {
            Task { await viewModel.tapMic() }
        } label: {
            ZStack {
                if viewModel.phase.isMicActive && !reduceMotion {
                    pulseRing
                }

                Circle()
                    .fill(buttonFill)
                    .frame(width: 72, height: 72)
                    .shadow(color: buttonShadow, radius: 24, y: 8)
                    .overlay { buttonIcon }
                    .scaleEffect(viewModel.phase.isMicActive ? 1.05 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.65), value: viewModel.phase.isMicActive)
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.phase.isBusy)
    }

    private var pulseRing: some View {
        Circle()
            .stroke(Color.red.opacity(0.5), lineWidth: 2)
            .frame(width: 88, height: 88)
            .scaleEffect(pulseScale)
            .opacity(pulseOpacity)
            .onAppear {
                guard !reduceMotion else { return }
                pulseScale = 1
                pulseOpacity = 0.6
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    pulseScale = 2
                    pulseOpacity = 0
                }
            }
            .onDisappear {
                pulseScale = 1
                pulseOpacity = 0
            }
    }

    private var buttonFill: Color {
        switch viewModel.phase {
        case .listening: return .red
        case .sending, .streaming: return .white.opacity(0.12)
        default: return .white.opacity(0.2)
        }
    }

    private var buttonShadow: Color {
        viewModel.phase.isMicActive ? .red.opacity(0.45) : .clear
    }

    @ViewBuilder
    private var buttonIcon: some View {
        if viewModel.phase.isBusy {
            ProgressView().tint(.white)
        } else if viewModel.phase.isSpeaking {
            Image(systemName: "speaker.wave.2.fill")
                .font(.title2)
                .foregroundStyle(.white)
        } else {
            Image(systemName: viewModel.phase.isMicActive ? "mic.fill" : "mic")
                .font(.title2)
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Turn bubble

private struct VoiceTurnBubbleView: View {
    let turn: VoiceTurn

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer(minLength: 48)
                Text(turn.user)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        Color.white.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
            }

            HStack {
                Text(turn.assistant)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        Color.white.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                Spacer(minLength: 48)
            }
        }
    }
}
