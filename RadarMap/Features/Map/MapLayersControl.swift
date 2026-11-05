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
//  С 20.10 кнопка и панель — две вью. Панель рисует слой меню над всем
//  экраном (MapScreen+Popovers): только оттуда касание мимо неё закрывает
//  её, не задевая карту и кнопки под пальцем. Кнопка отдаёт слою свою рамку
//  (MapPopoverAnchors), и панель встаёт там же, где стояла, — сбоку от неё.
//  С этапа 45 своей кнопки у панели нет: её открывает плитка «Карта» меню
//  «…», и встаёт она у круга «…».
//

import SwiftUI

/// Круг «…»: плитки «Ещё» над нижними панелями (этап 45). Панель «Карта»
/// из плитки встаёт у этого же круга — рамка слоёв у него своя.
struct MapMoreButton: View {
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        CircleControl(systemName: "ellipsis",
                      tint: isOpen ? Theme.accent : Theme.textPrimary,
                      accessibilityLabel: "Ещё",
                      action: action)
            .accessibilityAddTraits(isOpen ? .isSelected : [])
            .anchorPreference(key: MapPopoverAnchors.self, value: .bounds) { [.layers: $0] }
    }
}

/// Панель «Карта»: слои и кнопки масштаба.
struct MapLayersPanel: View {
    /// Пробки от водителей (TrafficService) — первым: это то, что смотрят
    /// перед выездом.
    @Binding var traffic: Bool
    @Binding var places: Bool
    /// Дома и тротуары своей схемы. Отдельными тумблерами, а не «подробнее»
    /// одной ручкой: платят за них по-разному (дома — 78 МБ из 347 по стране,
    /// тротуары — один), и нужны они разным людям.
    @Binding var houses: Bool
    @Binding var sidewalks: Bool
    /// Кнопки «+ / −» в колонке. Здесь, а не только в настройках: их
    /// включают и выключают, глядя на колонку, а не на список настроек (5.8).
    /// «Объёмный вид» — из колонки сюда (этап 31): переключают редко, а круг
    /// «3D» занимал место у камер правого края.
    @Binding var threeD: Bool
    @Binding var zoomButtons: Bool
    /// «Весь маршрут» — пока маршрут есть (плитка «Карта» меню «Ещё», этап 45).
    var onOverview: (() -> Void)? = nil
    /// Сколько панели можно занять по высоте — до нижних панелей экрана.
    /// Не влезает — листается, а не уезжает под них.
    var maxPanelHeight: CGFloat = .infinity
    let onClose: () -> Void

    /// Настоящая высота содержимого панели — мерится внутри ScrollView.
    @State private var contentHeight: CGFloat = 0
    /// Ширина по самой длинной подписи («Piyodalar yo‘lagi» и крупный
    /// кегль не помещались в прежние 208 pt), но не уже 208 (4.5).
    @State private var contentWidth: CGFloat = 0

    var body: some View {
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
        // Таймер простоя — от любого переключения внутри (MapPopoverCard).
        .mapPopoverCard(activity: [traffic, places, houses, sidewalks, threeD, zoomButtons], onClose: onClose)
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            MapPopoverHeader(title: "Карта", onClose: onClose)
            // Легенды под тумблером нет (владелец 28.10: «подсказку убери, там
            // не нужно»): цвета объясняет лист балла города (чип справа).
            toggle("Пробки", Icon.trafficLayer, isOn: $traffic)
            // «Места» прячут кафе и банки, заправки и парковки остаются всегда.
            toggle("Места", Icon.placesLayer, isOn: $places)
            toggle("Дома", Icon.buildingsLayer, isOn: $houses)
            toggle("Тротуары", Icon.sidewalksLayer, isOn: $sidewalks)
            toggle("Объёмный вид", "view.3d", isOn: $threeD)
            if let onOverview {
                Button(action: onOverview) {
                    HStack(spacing: 10) {
                        MapPopoverGlyph(systemName: "point.topleft.down.to.point.bottomright.curvepath", isOn: false)
                        Text("Весь маршрут")
                            .font(.rounded(14, .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 10)
                    }
                    .frame(minHeight: Theme.controlSize)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(.row))
            }
            Text("Кнопки")
                .font(.rounded(11, .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 8)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            toggle("Масштаб", Icon.zoomButtons, isOn: $zoomButtons)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
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
        } label: {
            HStack(spacing: 10) {
                // Значок — на кружке, как тумблеры «Оповещений»: включённый
                // слой — синий кружок с белым значком, выключенный — серый.
                // До 20.10 это был голый значок в 12 pt, и человечек
                // «Тротуаров» рядом с домами читался пятном.
                MapPopoverGlyph(systemName: icon, isOn: isOn.wrappedValue)
                Text(title)
                    .font(.rounded(14, .medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 10)
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.rounded(18))
                    .foregroundStyle(isOn.wrappedValue ? Theme.accent : Theme.textTertiary)
                    .frame(width: 44)
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
}
