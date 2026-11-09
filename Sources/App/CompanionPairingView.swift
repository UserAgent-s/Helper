import SwiftUI

enum PairingWindow {
    static let id = "companion-pairing"
}

struct CompanionPairingView: View {
    @Bindable var viewModel: CompanionPairingViewModel
    var navigationState: AppNavigationState
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc("Подключить устройство"))
                .font(.title2)
            content
            HStack {
                Spacer()
                Button(loc("Закрыть")) { close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("pairing.close")
            }
        }
        .padding(24)
        .frame(width: 420)
        .task {
            guard navigationState.consumePairingRequest() else {
                close()
                return
            }
            await viewModel.begin()
        }
        .onDisappear {
            Task { await viewModel.end() }
        }
        .onChange(of: viewModel.shouldClose) { _, shouldClose in
            if shouldClose { close() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            ProgressView()
        case .serverOff:
            Text(loc("Сервер веб-панели выключен. Включите его, чтобы подключить второе устройство."))
                .fixedSize(horizontal: false, vertical: true)
            Button(loc("Включить сервер")) { Task { await viewModel.turnOnServer() } }
                .accessibilityIdentifier("pairing.enableServer")
        case .noNetworkAddress:
            Text(loc("У этого Mac нет адреса в локальной сети. Подключитесь к Wi-Fi или включите доступ из сети в настройках."))
                .fixedSize(horizontal: false, vertical: true)
            Button(loc("Повторить")) { Task { await viewModel.regenerate() } }
        case .ready:
            readyContent
        case .expired:
            Text(loc("Код истёк."))
            Button(loc("Новый код")) { Task { await viewModel.regenerate() } }
                .accessibilityIdentifier("pairing.regenerate")
        case .paired(let name):
            Label(loc("Подключено:") + " \(name)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        if viewModel.isRevealed {
            HStack(alignment: .top, spacing: 16) {
                if let image = viewModel.qrImage {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .accessibilityLabel(loc("QR-код сопряжения"))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(loc("Отсканируйте QR на втором устройстве или откройте адрес и введите код."))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let panelURL = viewModel.panelURL {
                        Text(panelURL)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                    Text(viewModel.maskedNumericCode)
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .accessibilityIdentifier("pairing.code")
                    Button(loc("Скрыть код")) { viewModel.hide() }
                }
            }
        } else {
            Label(loc("Если вы сейчас показываете экран, сначала остановите демонстрацию: по коду можно подключиться из той же сети."), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text(viewModel.maskedNumericCode)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Button(loc("Показать код и QR")) { viewModel.reveal() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("pairing.reveal")
        }
        Text(loc("Код действует ещё") + " \(viewModel.remainingSeconds / 60):" + String(format: "%02d", viewModel.remainingSeconds % 60))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func close() {
        dismissWindow(id: PairingWindow.id)
    }
}
