//
//  MapScreen+TopPanels.swift
//  RadarMap
//
//  Главный экран: верхние панели, HUD, жесты HUD, плашка пассажира, оповещение о камере.
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit

extension MapScreen {

    /// «Вы на месте» на экране — вместо панели поездки (TripScreenLayout).
    var arrivalShown: Bool {
        TripScreenLayout.showsArrival(hasArrival: env.route.lastArrival != nil,
                                      isTripActive: env.location.isTripActive,
                                      showsTripEnd: tripEndRecord != nil)
    }

    @ViewBuilder var approachOverlay: some View {
        #if DEBUG
        // -hideCameraAlert: снимаем чистые кадры turn-by-turn (алерт камеры
        // полноэкранный и перекрывает баннер манёвра).
        if ProcessInfo.processInfo.arguments.contains("-hideCameraAlert") {
            EmptyView()
        } else if ProcessInfo.processInfo.arguments.contains("-demoAlert"),
                  let camera = env.location.currentCoordinate.flatMap({ env.cameras.nearest(to: $0, limit: 1).first })
                    ?? env.cameras.cameras.first {
            // Полноэкранное предупреждение на снимок — без поездки и движения.
            // Раскладка — по тому же правилу, что живое окно: с `-demoRoute`
            // это верхняя карточка над панелью маршрута (28.K).
            ApproachAlertView(camera: camera, distance: 240, speedKmh: 67, relativeBearing: 12,
                              alertRadius: 500,
                              layout: ProcessInfo.processInfo.arguments.contains("-demoAlertCard")
                                ? .bottomCard
                                : .current(isTripActive: env.location.isTripActive,
                                           hasRoute: env.route.isActive,
                                           isBuildingRoute: env.route.isBuilding),
                              onCardEdge: setAlertCardEdge,
                              onTopCardEdge: setAlertTopEdge,
                              onDismiss: {})
        } else {
            ApproachOverlayGate(dismissedID: $dismissedApproachID, onCardEdge: setAlertCardEdge,
                                onTopCardEdge: setAlertTopEdge)
        }
        #else
        ApproachOverlayGate(dismissedID: $dismissedApproachID, onCardEdge: setAlertCardEdge,
                            onTopCardEdge: setAlertTopEdge)
        #endif
    }

    /// Верхняя карточка предупреждения (выбор маршрута) — «я» и начало
    /// маршрута опускаются под неё (28.K).
    func setAlertTopEdge(_ edge: CGFloat?) {
        guard edge != alertTopEdge else { return }
        alertTopEdge = edge
        applySketchInsets()
    }

    /// Карточка предупреждения закрывает низ карты — «я» и камера встают
    /// над ней, а не под ней (ревью 19.10).
    func setAlertCardEdge(_ edge: CGFloat?) {
        guard edge != alertCardEdge else { return }
        alertCardEdge = edge
        applySketchInsets()
    }

    // MARK: - Умные кнопки

    // Автоскрытие интерфейса УДАЛЕНО, и это не упрощение ради упрощения.
    //
    // Механизм заводился правильной мыслью — в поездке максимум экрана отдан
    // карте, — но по факту не делал ничего. Он включался только под `guard
    // env.location.isTripActive`, а прятал ровно три вещи: легенду типов
    // камер, нижний бар действий и разовые подсказки. Все три показываются
    // ТОЛЬКО в покое (MapMode.showsLegend, showsActionBar). Таймер на пять
    // секунд, задача на каждое касание и анимация двух слоёв работали ради
    // состояния, которого не бывает.
    //
    // Проверять такие механизмы надо перебором режимов, а не на глаз: в план
    // я сначала записал «прячет нужное» — и это оказалось неверно.

    var crosshair: some View {
        Image(systemName: "scope")
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(Theme.accent)
            .shadow(color: .black.opacity(0.5), radius: 4)
            .allowsHitTesting(false)
    }

    // MARK: - Верх: HUD + подсказка

    /// Панели поверх карты сверху: объявления, HUD, тумблеры, манёвр.
    ///
    /// Отдельным свойством не ради красоты, а ради ЗАМЕРА: схеме нужно знать,
    /// докуда её закрыли, и мерить надо ровно эти панели — без кнопок справа
    /// (они не поперёк экрана) и без распорки.
    @ViewBuilder
    var topPanels: some View {
        VStack(spacing: 10) {
            // The next turn stays at a fixed top position as statuses appear.
            ManeuverBannerGate()
            // Объезд пробки и погода на перевале — вопросы на ходу внизу, в
            // панели поездки (этап 45): сверху в навигации — только дорога.
            // В навигации сверху — ОДНА карточка, манёвр. Камера на подходе —
            // компактным чипом под ней; скорость с лимитом — внизу слева
            // (bottomLayer). Две крупные карточки занимали треть экрана.
            if mode.speedPlacement == .bottomLeading {
                TripCameraChip()
            }
            // Почему приложение работает не в полную силу: объявление сервера,
            // серая карта без сети, урезанная карта в жару, отсутствие лимитов.
            // Выше всего, потому что человек должен узнать причину раньше, чем
            // упрётся в неё сам и решит, что приложение сломалось.
            MapStatusBanner(modernMap: true)
            // Доступ к геопозиции — сразу под объявлениями сервера, а не внизу
            // поверх карты: это причина, по которой приложение не предупреждает
            // в фоне, и место ей рядом с остальными «почему не в полную силу».
            permissionBanner
            // Тап по HUD — быстрые тумблеры оповещений (долгий тап — тоже).
            // HUD сверху всегда компактный: в покое главное «куда поедем», а в
            // поездке без маршрута полноразмерная карточка занимала пятую часть
            // экрана ради двух чисел. В навигации его здесь нет вовсе.
            if mode.speedPlacement == .top, !Self.screenshotHidesIdleHUD {
                // Стоя — компактный чип камеры (44 pt вместо 76): на стоянке
                // смотрят на карту, а не на прибор. Поехали — прежний HUD со
                // скоростью и лимитом.
                if SpeedHUDView.showsSpeed(isTripActive: env.location.isTripActive,
                                           isProbablyDriving: env.location.isProbablyDriving) {
                    hudGestures(SpeedHUDView(secondary: true))
                } else {
                    hudGestures(IdleCameraChip())
                }
            }
            // Разовые подсказки по жестам и экономии — по одной, не простынёй.
            if let hint = activeHint {
                HintChip(text: hint.text)
            }
            // «Мама увидит, что вы едете домой» — раз в день (22.1).
            FamilyNoticeChip()
            if showBatterySaverHint {
                HintChip(text: String(localized: "Батарея садится — погасите экран, о камерах скажу голосом"),
                         tint: Theme.success)
            }
            // «Я в такси»: приложение молчит осознанно — человек должен видеть,
            // почему нет оповещений, и уметь передумать одним тапом.
            if env.location.isPassengerSession {
                passengerChip
            }
            // Быстрых тумблеров («Оповещения») здесь больше нет — они в слое
            // меню над экраном (MapScreen+Popovers), и встают под этой
            // стопкой по её рамке. Правило прежнее (plan_app_ui.md, У11):
            // ничто над ними не двигается, манёвр остаётся под взглядом.
            // Теперь не двигается и то, что ПОД ними: колонка кнопок и сама
            // карта (кромка панелей для «я» их больше не считает).
        }
    }

    /// DEBUG `-hideIdleHUD`: кадр выбора маршрута для App Store без карточки
    /// «444 м до радара» — в покое ближайшая камера есть всегда (окно — 150
    /// ближайших, без предела по расстоянию), и снять экран выбора без неё
    /// иначе нельзя. В релизе всегда false.
    static var screenshotHidesIdleHUD: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-hideIdleHUD")
        #else
        false
        #endif
    }

    var topLayer: some View {
        VStack(spacing: 10) {
            topPanels
                // Рамка стопки — меню «Оповещения» встаёт под ней (20.10).
                .anchorPreference(key: MapPopoverAnchors.self, value: .bounds) { [.quickToggles: $0] }
                // Кромка панелей — схеме.
                //
                // Схема лежит во весь экран, а видно из неё столько, сколько
                // оставили панели: 17 % высоты забирает карточка скорости, 26 %
                // — она же с объявлением о перегреве. Пока проекция считала от
                // ПОЛНОГО экрана, тревожная камера садилась на 12 % сверху, то
                // есть ПОД карточкой: на снимке живой поездки «344 м до камеры»
                // в карточке и ни одной камеры на карте.
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                    topPanelEdge = $0 + 8
                    applySketchInsets()
                    updateColumnSlots()
                }
            // Кнопки навигации — сразу под HUD справа. Не прячутся по таймеру
            // (см. controlColumn), но уходят под карточкой прибытия: это
            // последний экран поездки, и крутить карту в этот момент незачем.
            if TripScreenLayout.showsControlColumn(arrivalShown: arrivalShown,
                                                   isAddingCamera: map.isAddingCamera) {
                HStack {
                    Spacer()
                    controlColumn
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Вход HUD — быстрые тумблеры (звук, вибро, голос). Один и тот же у HUD
    /// сверху и у скорости внизу слева в навигации — жест не должен зависеть
    /// от того, где сейчас стоит цифра.
    ///
    /// Тап раньше открывал спидометр, а тумблеры жили за долгим тапом, о
    /// котором рассказывала отдельная подсказка. Спидометр убран, и тап
    /// достался тому, ради чего к HUD тянутся на ходу, — «хватит болтать».
    /// Долгий тап оставлен с тем же действием: рука, привыкшая к нему, не
    /// должна наткнуться на пустоту.
    func hudGestures(_ content: some View) -> some View {
        content
            .onTapGesture { toggleQuickToggles() }
            .onLongPressGesture(minimumDuration: 0.4) { toggleQuickToggles() }
            // Жестов для VoiceOver не существует — вход даём действием.
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Открывает быстрые тумблеры"))
            .accessibilityAction { toggleQuickToggles() }
    }

    func toggleQuickToggles() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        send(.toggle(.quickToggles))
    }

    /// Баннер пассажирского режима: молчание — осознанное, выход — один тап.
    var passengerChip: some View {
        Button {
            // Тот же путь, что «Я за рулём» из уведомления: сброс пассажирского
            // флага, запоминание магнитолы, старт поездки.
            env.location.confirmDriver()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "figure.seated.seatbelt")
                    .font(.rounded(13, .semibold))
                Text("Вы пассажир — оповещения выключены")
                    .font(.rounded(12, .semibold))
                Spacer(minLength: 4)
                Text("Я за рулём")
                    .font(.rounded(12, .bold))
                    .foregroundStyle(Theme.accent)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.controlSize)
            .liftedBackground(Theme.surface, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
