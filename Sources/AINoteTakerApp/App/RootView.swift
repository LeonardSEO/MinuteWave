import SwiftUI

struct RootView: View {
    @StateObject var viewModel: AppViewModel

    var body: some View {
        Group {
            if viewModel.settings.onboardingCompleted {
                MainWorkspaceView(viewModel: viewModel)
            } else {
                OnboardingWizardView(viewModel: viewModel)
            }
        }
        .environment(\.locale, viewModel.resolvedLocale)
        .background(WindowConfigurator())
        .task {
            await viewModel.bootstrap()
        }
        .alert(
            L10n.tr("ui.error.title"),
            isPresented: Binding(
                get: { viewModel.transientError != nil },
                set: { if !$0 { viewModel.transientError = nil } }
            ),
            presenting: viewModel.transientError
        ) { _ in
            Button(L10n.tr("ui.common.ok")) {
                viewModel.transientError = nil
            }
        } message: { error in
            if let detail = error.technicalDetail, !detail.isEmpty {
                Text("\(error.userMessage)\n\n\(L10n.tr("ui.error.technical_detail_prefix")) \(detail)")
            } else {
                Text(error.userMessage)
            }
        }
    }
}
