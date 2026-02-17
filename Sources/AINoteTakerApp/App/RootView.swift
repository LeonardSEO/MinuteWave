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
            "Error",
            isPresented: Binding(
                get: { viewModel.transientError != nil },
                set: { if !$0 { viewModel.transientError = nil } }
            ),
            presenting: viewModel.transientError
        ) { _ in
            Button("OK") {
                viewModel.transientError = nil
            }
        } message: { message in
            Text(message)
        }
    }
}
