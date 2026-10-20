//
//  MapScreen+BottomPanels.swift
//  RadarMap
//
//  Главный экран: нижние панели — маршрут, точка на карте, конец поездки, заезд.
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit

extension MapScreen {

    // MARK: - Низ: панель действий / режим добавления

    /// Панели поверх карты снизу: панель поездки, плашки, кнопки действий.
    ///
    /// Отдельным свойством по той же причине, что и верхние: схема обязана
    /// знать, докуда её закрыли снизу, а измерить это можно только у самих
    /// панелей — у стопки с распоркой высота всегда во весь экран.
    @ViewBuilder
    var bottomPanels: some View {
        VStack(spacing: 10) {
            if map.isAddingCamera {
                AddCameraBar(
                    onCancel: { map.isAddingCamera = false },
                    onAdd: { kind, name in addCamera(kind: kind, name: name) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let point = map.pressedPoint {
                MapPointBar(
                    title: point.title,
                    onRoute: !env.location.hasLocation ? nil : {
                        buildRoute(to: point.coordinate, name: point.title ?? String(localized: "Точка на карте"))
                        withMotion { map.pressedPoint = nil }
                    },
                    onRadar: {
                        withMotion {
                            map.pressedPoint = nil
                            reportPoint = point   // дальше — выбор типа отметки
                        }
                    },
                    onOwnCamera: {
                        // Крестик режима добавления встаёт на выбранную точку —
                        // пользователь при желании доводит позицию вручную.
                        withMotion {
                            map.pressedPoint = nil
                            map.center(on: point.coordinate)
                            map.isAddingCamera = true
                        }
                    },
                    onCancel: {
                        withMotion { map.pressedPoint = nil }
                    }
                )
            } else if let report = reportPoint {
                ReportPickerBar(
                    roadKinds: env.mobile.roadEventsSupported ? ReportKind.roadOffered : [],
                    onPick: { kind in
                        // Место показано пальцем, тип выбран из списка — это
                        // осознанная постановка: проверку «вы стоите» она
                        // проходит, а защиту от дублей и счётчик получает.
                        // Отклик — ПО ИТОГУ, а не сразу: прежний безусловный
                        // «успех» звучал одинаково и когда отметка ушла, и
                        // когда её отбросили как дубль.
                        Task {
                            let outcome = await env.mobile.quickReport(
                                kind: kind,
                                coordinate: report.coordinate,
                                speedKmh: env.location.speedKmh,
                                isTripActive: env.location.isTripActive,
                                placement: .deliberate)
                            UINotificationFeedbackGenerator()
                                .notificationOccurred(outcome.isSuccess ? .success : .warning)
                        }
                        withMotion { reportPoint = nil }
                    },
                    onCancel: { withMotion { reportPoint = nil } }
                )
            } else {
                // «Радар ещё стоял?» — над панелью поездки: вопрос живёт
                // двадцать секунд и уходит сам, ничего не отправляя. Пока на
                // экране предупреждение о камере, вопрос ждёт: камера важнее,
                // а под оверлеем плашка сгорала невидимой.
                // Условие «накрыто» — в гейте: isApproachingCamera читает
                // пер-тиковые дистанцию и скорость (см. MapTickGates).
                MobileConfirmGate()
                // «Что это было?» — уточнение типа сразу после «Радар!»:
                // тот же гейт-паттерн и то же место над панелью поездки.
                ReportRefineGate()
                // «Опаздываю — предупредить?» — со сроком, стоя, раз за поездку.
                GhostLateGate { text in lateSharePayload = ActivityTextPayload(text: text) }
                // Итог поездки — сразу после стопа, в момент, когда цифры
                // интереснее всего (см. maybeShowTripEnd про условия показа).
                if let record = tripEndRecord {
                    TripEndCard(
                        record: record,
                        onDetail: { chosen in
                            withMotion(Motion.standard) { tripEndRecord = nil }
                            tripEndDetail = chosen
                        },
                        onMerged: { tripEndRecord = env.trip.history.first },
                        onDismiss: {
                            withMotion(Motion.standard) { tripEndRecord = nil }
                        })
                }
                if arrivalShown, let arrival = env.route.lastArrival {
                    // «Вы на месте» — НА МЕСТЕ панели поездки, а не поверх
                    // экрана: у карточки своя «Завершить поездку», и второй
                    // «стоп» рядом с ней означал бы вопрос, какой настоящий.
                    ArrivalCardView(arrival: arrival, onDismiss: {
                        withMotion(Motion.standard) { env.route.dismissArrival() }
                    })
                } else if TripScreenLayout.showsTripBar(mode: mode, arrivalShown: arrivalShown) {
                    // Панель поездки — ниже, после всей цепочки: одна на все
                    // ветки (см. там). Здесь ветка лишь занимает её место,
                    // чтобы маршрут и подсказки не встали вместо неё.
                    EmptyView()
                } else if mode.showsRoutePanel, env.route.isActive {
                    RoutePanel(
                        onShowCameras: { showRouteCameras = true },
                        onTripToggle: { toggleTrip() },
                        onRemoveStop: { removeStop() },
                        onShareArrival: { shareArrival() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    // ОДНА плашка, а не четыре разом.
                    //
                    // Каждая заводилась по своей причине и права по
                    // отдельности; вместе они делили внимание на четыре — за
                    // рулём, где на взгляд есть доля секунды. Приоритет
                    // считается один раз (BottomHint.choose) и не
                    // оспаривается: требующее решения старше сообщающего.
                    switch BottomHint.choose(
                        routeError: env.route.errorMessage,
                        isBuilding: env.route.isBuilding,
                        isProbablyDriving: env.location.isProbablyDriving,
                        showsQuickDestinations: mode.showsQuickDestinations) {
                    case .routeError(let error):
                        // Тап убирает ошибку — значит, это кнопка, и мишень у
                        // неё 44 pt (была капсула ~28 pt под onTapGesture).
                        Button { env.route.clear() } label: {
                            Text(error)
                                .font(.rounded(12, .medium)).foregroundStyle(Theme.danger)
                                .padding(.horizontal, 14)
                                .frame(minHeight: Theme.controlSize)
                                .liftedBackground(Theme.surface, in: Capsule())
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityHint(Text("Убрать сообщение"))
                    case .building:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Строим маршрут…")
                                .font(.rounded(12, .medium)).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .liftedBackground(Theme.surface, in: Capsule())
                    case .driving:
                        // Только старт: подсказка живёт до следующего фикса,
                        // и второе касание через toggle завершало бы поездку.
                        DrivingHintChip {
                            if !env.location.isTripActive { toggleTrip() }
                        }
                    case .destinations:
                        // Куда поедем — одной строкой и только когда есть
                        // уверенная догадка. Два круга Дом/Работа стояли здесь
                        // всегда, и незаданные выглядели невыполненным
                        // заданием от приложения человеку; распорядок оно
                        // знает само (FrequentPlaces).
                        // Разовое «Карта без интернета?» — до первого ответа.
                        // Где оставили машину — капсулой, пока отошли от неё.
                        ParkedCarChip(map: map)
                        OfflineOfferCard(ownMap: true)
                        DestinationSuggestionBar { coordinate, name in
                            buildRoute(to: coordinate, name: name)
                        }
                        tripButton
                    case .none:
                        EmptyView()
                    }
                }
                if mode.showsActionBar {
                    actionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // В поездке: компактная строка (прибытие · остаток · камера · стоп) —
            // максимум экрана отдан карте, и она не прячется вместе с кнопками.
            //
            // ОДНА на все ветки и всегда последним ребёнком стопки. Точка на
            // карте или выбор типа отметки встают НАД ней: раньше долгий тап
            // на ходу убирал «Радар!» и «Стоп», а когда панель вернули второй
            // копией в другой ветке, SwiftUI считал их разными видами — на
            // 0,3 с анимации на экране было две панели и сбрасывался
            // взведённый «Стоп».
            if !map.isAddingCamera,
               TripScreenLayout.showsTripBar(mode: mode, arrivalShown: arrivalShown) {
                TripLiveBar(
                    onShowCameras: { showRouteCameras = true },
                    onStop: { toggleTrip() }
                )
            }
        }
    }

    var bottomLayer: some View {
        VStack(spacing: 10) {
            Spacer()
            // Скорость и лимит в навигации — внизу слева, над панелью поездки.
            // Вне замера кромки: это угол, а не полоса поперёк экрана, и
            // карта под ним видна справа.
            if mode.speedPlacement == .bottomLeading, !arrivalShown, !map.isAddingCamera {
                HStack {
                    hudGestures(TripSpeedCluster())
                    Spacer(minLength: 0)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            bottomPanels
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                    bottomPanelEdge = $0 - 8
                    applySketchInsets()
                    updateColumnSlots()
                }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .motionAnimation(Motion.standard, value: map.isAddingCamera)
        .motionAnimation(Motion.standard, value: map.pressedPoint)
        .motionAnimation(Motion.standard, value: reportPoint)
        .motionAnimation(Motion.standard, value: arrivalShown)
    }

    /// Долгий тап: маркер + бар действий (кроме режима прицела добавления камеры).
    func selectPoint(at coordinate: CLLocationCoordinate2D) {
        guard !map.isAddingCamera,
              TripScreenLayout.allowsMapLongPress(isTripActive: env.location.isTripActive,
                                                  speedKmh: env.location.speedKmh,
                                                  isProbablyDriving: env.location.isProbablyDriving)
        else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withMotion(Motion.standard) {
            map.pressedPoint = MapPoint(coordinate: coordinate)
        }
    }

    func toggleTrip() {
        if env.location.isTripActive {
            env.location.endTrip()
        } else {
            env.location.startTrip()
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Показать «Поездка сохранена» после стопа. Только на переднем плане
    /// (автозавершение в кармане обслуживает уведомление, а не карточка,
    /// которую никто не видит), только для свежесохранённой записи (короче
    /// 100 м поездка не пишется вовсе — свежести нет, карточки нет) и не
    /// поверх открытых Итогов — там те же цифры уже на экране.
    func maybeShowTripEnd() {
        // Свежесть — по моменту СОХРАНЕНИЯ, а не по endedAt записи: endedAt —
        // это последний фикс, а на стоянке фиксов нет. Минута у подъезда — и
        // только что сохранённая поездка считалась старой, карточка не
        // появлялась, и поездка выглядела пропавшей («после него куда делся»).
        guard scenePhase == .active, !map.showStats,
              TripScreenLayout.isTripEndFresh(savedAt: env.trip.lastSavedAt, now: Date()),
              let record = env.trip.history.first else { return }
        withMotion(.spring(duration: 0.4)) {
            tripEndRecord = record
            // Итог поездки сказал всё, что говорила карточка прибытия, и больше.
            env.route.dismissArrival()
        }
    }

    func removeStop() {
        Task {
            guard let from = await env.location.awaitPreciseCoordinate() else {
                env.route.reportNoFixForStop()
                return
            }
            await env.route.removeStop(from: from, cameras: env.cameras.cameras)
        }
    }

    /// Ссылка «Поделиться прибытием» — один путь для меню поездки и панели
    /// маршрута: отправка начнётся, только когда лист скажет, что отправили.
    func shareArrival() {
        if let share = env.etaShare.prepare() { etaSharePayload = ActivityTextPayload(text: share.message) }
    }

    /// Построить авто-маршрут от текущей позиции и показать все варианты целиком.
    /// Заезд по пути (АЗС, кафе из плитки категории): цель остаётся прежней.
    func addStop(_ coordinate: CLLocationCoordinate2D, name: String) {
        Task {
            guard let from = await env.location.awaitPreciseCoordinate() else {
                env.route.reportNoFix()
                return
            }
            await env.route.addStop(coordinate, name: name, from: from,
                                    cameras: env.cameras.cameras)
        }
    }

    func buildRoute(to coordinate: CLLocationCoordinate2D, name: String) {
        Task {
            // Только от ЖИВОЙ точки. Раньше здесь стоял currentCoordinate без
            // проверки isPositionCoarse — а в него пишется и грубая точка
            // фонового режима, из-за чего маршрут «начинал считаться» за
            // километры от машины (plan_drive_complaints.md, Ж5).
            guard let from = await env.location.awaitPreciseCoordinate() else {
                env.route.reportNoFix()
                return
            }
            await env.route.build(from: from, to: coordinate, name: name,
                                  cameras: env.cameras.cameras,
                                  alternatives: env.settings.routeAlternatives)
            guard env.route.isActive else { return }
            env.settings.addRecent(title: name, lat: coordinate.latitude, lon: coordinate.longitude)
            // Охватываем ВСЕ варианты, чтобы выбор был виден сразу.
            var rect = MKMapRect.null
            for variant in env.route.variants { rect = rect.union(variant.polyline.boundingMapRect) }
            // Показываем маршрут целиком — это уже не слежение за точкой;
            // общая команда видна и карте Apple, и движку.
            map.showRouteOverview(rect: rect)
        }
    }
}
