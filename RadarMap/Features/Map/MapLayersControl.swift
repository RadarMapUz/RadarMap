//
//  MapLayersControl.swift
//  RadarMap
//
//  Слои карты — ОДНА панель, доступная в любом режиме.
//
//  До неё было две. Подложка (Apple / своя схема / движок) выбиралась двумя
//  тумблерами в десятом разделе настроек и вступала в силу только после старта
//  поездки: четыре тапа, прокрутка мимо девяти разделов и обязательная
//  поездка, чтобы увидеть результат. А слои подложки (пробки, места) жили в
//  своей панели, которая показывалась ТОЛЬКО на стоянке, — то есть в поездке
//  пробки нельзя было включить ничем.
//
//  Замерено у соседей: у Google, Apple, Яндекса и 2ГИС смена слоя — два
//  касания, и результат виден до закрытия панели. Здесь так же.
//
//  Свёрнутая кнопка показывает ВЫБРАННУЮ подложку, а не абстрактные «слои»:
//  состояние читается, не открывая панель.
//

import SwiftUI

struct MapLayersControl: View {
    /// Пробки от водителей (TrafficService) — первым: это то, что смотрят
    /// перед выездом.
    @Binding var traffic: Bool
    @Binding var places: Bool
    /// Дома и тротуары своей схемы. Отдельными тумблерами, а не «подробнее»
    /// одной ручкой: платят за них по-разному (дома — 78 МБ из 347 по стране,
    /// тротуары — один), и нужны они разным людям.
    @Binding var houses: Bool
    @Binding var sidewalks: Bool
    /// Сколько панели можно занять по высоте — до нижних панелей экрана.
    /// Не влезает — листается, а не уезжает под них.
    var maxPanelHeight: CGFloat = .infinity

    @State private var isExpanded = false
    @State private var collapseTask: Task<Void, Never>?
    /// Настоящая высота содержимого панели — мерится внутри ScrollView.
    @State private var contentHeight: CGFloat = 0
    /// Ширина по самой длинной подписи («Piyodalar yo‘lagi» и крупный
    /// кегль не помещались в прежние 208 pt), но не уже 208 (4.5).
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        // Панель открывается СБОКУ от кнопки, поверх карты, и в вёрстке
        // колонки не участвует. Раньше она вставала в колонку над кнопкой —
        // 208×~350 pt — и сталкивала вниз все кнопки под собой, на маленьком
        // iPhone за край экрана и под нижние панели.
        CircleControl(systemName: "square.3.layers.3d",
                      tint: isExpanded ? Theme.accent : Theme.textPrimary,
                      accessibilityLabel: "Слои карты") {
            isExpanded.toggle()
            postpone()
        }
        .overlay(alignment: .topTrailing) {
            if isExpanded {
                panel
                    .offset(x: -(Theme.controlSize + 10))
            }
        }
        .motionAnimation(.spring(duration: 0.32, bounce: 0.16), value: isExpanded)
        .onDisappear { collapseTask?.cancel() }
    }

    private var panel: some View {
        ScrollView {
            panelContent
                .onGeometryChange(for: CGSize.self) { $0.size } action: {
                    contentHeight = $0.height
                    contentWidth = $0.width
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: max(Self.minWidth, min(contentWidth, Self.maxWidth)),
               height: contentHeight > 0 ? min(contentHeight, max(maxPanelHeight, Theme.controlSize)) : nil)
        // Сплошная, как все панели над живой картой (4.2): стекло с вуалью
        // пересчитывало размытие каждый кадр и пропускало подписи улиц.
        .liftedBackground(Theme.surface,
                          in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous)
            .strokeBorder(Theme.edgePanel, lineWidth: 1))
        .transition(.scale(scale: 0.86, anchor: .topTrailing).combined(with: .opacity))
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Карта")
                .font(.rounded(11, .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 2)
            toggle("Пробки", "car.2.fill", isOn: $traffic)
            // «Места» прячут кафе и банки, заправки и парковки остаются всегда.
            toggle("Места", Icon.placesLayer, isOn: $places)
            toggle("Дома", Icon.buildingsLayer, isOn: $houses)
            toggle("Тротуары", "figure.walk", isOn: $sidewalks)
        }
        .padding(12)
        .frame(minWidth: Self.minWidth, alignment: .leading)
        // Идеальная ширина, а не предложенная ScrollView: иначе панель
        // измеряла бы саму себя.
        .fixedSize(horizontal: true, vertical: false)
    }

    private static let minWidth: CGFloat = 208
    private static let maxWidth: CGFloat = 280

    private func toggle(_ title: LocalizedStringKey, _ icon: String,
                        isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            postpone()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(isOn.wrappedValue ? Theme.accent : Theme.textTertiary)
                    .frame(width: 26)
                Text(title)
                    .font(.rounded(13, .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 10)
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.rounded(14))
                    .foregroundStyle(isOn.wrappedValue ? Theme.accent : Theme.textTertiary)
            }
            .frame(minHeight: Theme.controlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Галочка — картинка: без признака VoiceOver читал «Места, кнопка»
        // и включённый слой не отличался от выключенного (4.6).
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
        .accessibilityValue(isOn.wrappedValue ? Text("включено") : Text("выключено"))
    }

    /// Панель закрывается сама: открытой она занимает четверть экрана, а
    /// водитель, отвлёкшийся после нажатия, закрывать её не станет.
    private func postpone() {
        collapseTask?.cancel()
        guard isExpanded else { return }
        collapseTask = Task {
            await Task.pause(seconds: 6)
            guard !Task.isCancelled else { return }
            isExpanded = false
        }
    }
}
