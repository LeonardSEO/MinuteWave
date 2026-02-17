import SwiftUI

struct LocalPreparationOverlay: View {
    let state: AppViewModel.StartupPreparationState

    var body: some View {
        if state.isActive && !state.isReady {
            HStack(spacing: 12) {
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 180)

                VStack(alignment: .leading, spacing: 4) {
                    Text(state.statusTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(state.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Text("\(Int((state.progress * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
