import SwiftUI
import OverlayReducer
import Domain

struct AnswerOverlayContentView: View {
    var viewModel: AnswerOverlayViewModel
    var style: OverlayStyle = .floating
    var fontFamily: OverlayFontFamily = .sans
    var onCopy: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var answerPanelSize: CGSize {
        switch style {
        case .pinned: CGSize(width: 420, height: 280)
        case .floating: CGSize(width: 520, height: 360)
        case .fullscreen: CGSize(width: 900, height: 620)
        }
    }

    private var bodyFont: Font {
        Font(fontFamily.font(size: style == .fullscreen ? 22 : 15))
    }

    var body: some View {
        mainContent
            .frame(
                maxWidth: style == .fullscreen ? .infinity : nil,
                maxHeight: style == .fullscreen ? .infinity : nil
            )
    }

    private var mainContent: some View {
        Group {
            switch viewModel.state.visibility {
            case .hidden:
                EmptyView()
            case .collectingContext:
                capsule(systemImage: "ear", text: loc("Слушаю"), showForceAnswerButton: true)
            case .manualResponsePending:
                capsule(systemImage: "hourglass", text: loc("Жду окончания фразы…"), showForceAnswerButton: false)
            case .reconnecting:
                capsule(systemImage: "wifi.exclamationmark", text: loc("Переподключение…"), showForceAnswerButton: false)
            case .streaming, .completed:
                answerPanel
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: viewModel.state.visibility)
        .overlay(alignment: .top) {
            if viewModel.showNoContextToast {
                toast(loc("Нет контекста для ответа"))
                    .accessibilityLabel(loc("Нет контекста для ответа"))
            } else if let notice = viewModel.captureNotice {
                toast(Self.text(for: notice))
                    .accessibilityLabel(Self.text(for: notice))
            }
        }
        .background(containerBackground)
    }

    static func text(for notice: CaptureNotice) -> String {
        switch notice {
        case .fellBackToWholeSystem(let missingBundleID):
            return "«\(missingBundleID)» " + loc("не запущено, слушаю весь системный звук")
        case .systemCaptureRestarted:
            return loc("Захват системного звука перезапущен")
        case .microphoneFellBack(_, let to, .continuityDefault), .microphoneFellBack(_, let to, .continuitySelected):
            return loc("Микрофон iPhone пропущен, пишу с") + " «\(to)»"
        case .microphoneFellBack(_, let to, .selectedDeviceMissing):
            return loc("Выбранный микрофон недоступен, пишу с") + " «\(to)»"
        case .outputRouteChanged(let route):
            return loc("Вывод звука:") + " " + routeText(route)
        case .meTranscriptionUnavailable:
            return loc("Канал «Я» недоступен, ответы продолжают работать без ваших реплик")
        }
    }

    static func routeText(_ route: OutputRoute) -> String {
        switch route {
        case .builtInSpeakers: return loc("динамики Mac")
        case .wiredHeadphones: return loc("проводные наушники")
        case .bluetoothHeadphones(let name): return loc("Bluetooth-наушники") + " «\(name)»"
        case .airPlay(let name): return "AirPlay «\(name)»"
        case .external(let name): return loc("внешнее устройство") + " «\(name)»"
        case .unknown: return loc("не определён")
        }
    }

    @ViewBuilder
    private var containerBackground: some View {
        if style == .pinned {
            DynamicIslandShape(topInset: 16, bottomRadius: 18).fill(Color.black)
        } else {
            Color.clear
        }
    }

    private func capsule(systemImage: String, text: String, showForceAnswerButton: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
            if showForceAnswerButton {
                Button(loc("Ответить сейчас")) {
                    viewModel.forceAnswerNow()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(loc("Принудительно отвечает по уже накопленному контексту"))

                if viewModel.state.lastAnswerText != nil {
                    Button {
                        viewModel.showLastAnswer()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel(loc("Показать последний ответ"))
                }

                Button {
                    viewModel.resetContext()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .accessibilityLabel(loc("Сбросить контекст"))
                .accessibilityHint(loc("Удаляет накопленный контекст и начинает заново"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(style == .pinned ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.regularMaterial), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var answerPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(viewModel.state.text)
                    .font(bodyFont)
                    .foregroundStyle(style == .pinned ? .white : .primary)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                    .textSelection(.enabled)
                    .accessibilityLabel(viewModel.state.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if viewModel.state.visibility == .completed {
                    Button {
                        onCopy(viewModel.state.text)
                    } label: {
                        Label(loc("Копировать"), systemImage: "doc.on.doc")
                    }
                    .accessibilityHint(loc("Копирует финальный ответ"))
                }

                Button {
                    viewModel.resetContext()
                } label: {
                    Label(loc("Сбросить"), systemImage: "arrow.counterclockwise")
                }
                .accessibilityHint(
                    viewModel.state.visibility == .completed
                        ? loc("Скрывает показанный ответ. Прослушивание продолжается без перерыва.")
                        : loc("Прерывает генерацию и удаляет накопленный контекст")
                )

                Spacer()
            }
            .font(.caption)
        }
        .padding(12)
        .background(style == .pinned ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 12))
        .frame(width: answerPanelSize.width, height: answerPanelSize.height, alignment: .topLeading)
    }

    private func toast(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
            .transition(.opacity)
    }
}
