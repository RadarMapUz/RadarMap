//
//  MapScreen+Popovers.swift
//  RadarMap
//
//  Главный экран: меню на карте — «Карта» (слои) и «Оповещения» (быстрые
//  тумблеры) — и ловушка касаний под ними (20.10).
//
//  Меню рисуется в слое над ВСЕМ экраном, а не рядом со своей кнопкой. Иначе
//  касание мимо него попадало бы в то, что лежит в стопке выше: нижние
//  панели нарисованы поверх верхних, и «закрыть меню» нажимало бы «Поиск»
//  или «Начать поездку». Под меню — прозрачная ловушка во весь экран: она
//  забирает касание и перетаскивание, закрывает меню и больше ничего не
//  делает — карта не сдвигается, точка долгим нажатием не ставится, кнопка
//  под пальцем не нажимается. Место меню берётся из рамки его кнопки
//  (MapPopoverAnchors), поэтому на экране оно стоит там же, где стояло.
//

import SwiftUI
import os

extension MapScreen {

    /// Событие для открытого меню — через чистую логику MapPopover.next.
    func send(_ event: MapPopover.Event) {
        let next = MapPopover.next(popover, on: event)
        guard next != popover else { return }
        // В журнал — чтобы «меню закрылось само» разбиралось по логу
        // устройства: кнопка, касание мимо, лист или таймер простоя.
        Log.app.debug("меню на карте: \(String(describing: event), privacy: .public) → \(String(describing: next), privacy: .public)")
        withMotion(Motion.standard) { popover = next }
    }

    /// Открыт ли поверх карты какой-нибудь её лист. Меню под листом — это
    /// меню, которое встретит человека после листа, когда он о нём забыл.
    /// Листы открываются кнопками, которые меню и так закрывает ловушкой;
    /// остаются диплинки (виджет, уведомление) и ключи запуска.
    var isSheetShown: Bool {
        map.selectedCamera != nil || map.showNearbySheet || map.showSearch || map.showSettings
            || map.showStats || showRouteCameras || showAlongRoute || showLongTrip || showMyPlaces || showsWhatsNew
            || showFines || tripEndDetail != nil || etaSharePayload != nil || lateSharePayload != nil
    }

    /// Слой меню: ловушка касаний и открытое меню на месте своей кнопки.
    ///
    /// Пока меню закрыто, слой пуст и касаний не берёт. Нет рамки (кнопка
    /// ушла с экрана) — нет ни меню, ни ловушки: невидимая ловушка без меню
    /// заперла бы весь экран.
    func popoverLayer(_ anchors: [MapPopover: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            let open = popover.flatMap { card in anchors[card].map { (card: card, rect: proxy[$0]) } }
            ZStack(alignment: .topLeading) {
                // Опора во весь слой: направляющие сдвигают меню относительно
                // соседей по стопке, и без соседа во весь экран сдвигать его
                // было бы не от чего. Касаний не берёт.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                if let open {
                    popoverCard(open.card, at: open.rect)
                }
            }
            .background {
                if open != nil { outsideCatcher }
            }
        }
    }

    /// Прозрачная ловушка во весь экран под меню.
    ///
    /// Касание закрывает меню; перетаскивание — тоже, с первых пунктов: «взял
    /// карту, чтобы сдвинуть» значит «меню больше не нужно». Сама карта при
    /// этом не едет — её жест забран ловушкой, и второе движение уже двигает
    /// карту без меню. VoiceOver ловушку не видит: у него меню модальное и
    /// закрывается крестиком или жестом «назад» (MapPopoverCard).
    private var outsideCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { send(.outsideTouch) }
            .simultaneousGesture(
                DragGesture(minimumDistance: AppConfig.mapPopoverDragSlop)
                    .onChanged { _ in send(.outsideTouch) })
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    /// Меню на месте: «Карта» — слева от кнопки слоёв, вровень с её верхом;
    /// «Оповещения» — под стопкой верхних панелей, во всю её ширину.
    ///
    /// Сдвиг — направляющими, а не отступами: рамка меню остаётся его
    /// собственной, и появление «из кнопки» (масштаб от угла) считается от
    /// угла меню, а не от угла экрана.
    @ViewBuilder
    private func popoverCard(_ card: MapPopover, at rect: CGRect) -> some View {
        let gap = AppConfig.mapPopoverGap
        switch card {
        case .layers:
            MapLayersPanel(traffic: setting(\.trafficShown),
                           places: setting(\.mapPlaces),
                           houses: setting(\.mapHouses),
                           sidewalks: setting(\.mapSidewalks),
                           threeD: Binding(get: { env.settings.map3D },
                                           set: { on in
                                               env.settings.map3D = on
                                               map.prefers3D = on
                                           }),
                           zoomButtons: setting(\.mapZoomButtons),
                           maxPanelHeight: columnSlots.map {
                               CGFloat($0) * AppConfig.mapColumnSlotHeight - AppConfig.mapColumnSpacing
                           } ?? .infinity,
                           onClose: { send(.dismissed(.layers)) })
                .alignmentGuide(.leading) { $0.width - (rect.minX - gap) }
                .alignmentGuide(.top) { _ in -rect.minY }
                .transition(.scale(scale: 0.86, anchor: .topTrailing).combined(with: .opacity))
        case .quickToggles:
            // Пустая стопка (бывает в навигации без плашек) — меню с её
            // верха, а не на зазор ниже пустоты.
            let top = rect.height < 1 ? rect.minY : rect.maxY + gap
            QuickTogglesBar { send(.dismissed(.quickToggles)) }
                .frame(width: rect.width)
                .alignmentGuide(.leading) { _ in -rect.minX }
                .alignmentGuide(.top) { _ in -top }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
