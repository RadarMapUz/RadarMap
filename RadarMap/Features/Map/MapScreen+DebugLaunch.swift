//
//  MapScreen+DebugLaunch.swift
//  RadarMap
//
//  DEBUG-ключи запуска для снимков экранов (-showStats, -settingsPage, …).
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit
import os

extension MapScreen {

    #if DEBUG
    /// Скриншот-автоматизация (симулятор): `simctl launch <app> -showStats | -showSettings |
    /// -showCameraDetail` открывает нужный экран без тапов. В релизную сборку не попадает.
    func openScreenFromLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        // Демо-история для визуальной проверки Итогов и отчёта за период.
        // -demoBigNumbers: та же история, но с четырёхзначными километрами —
        // вёрстку Итогов надо проверять на числах, которые бывают в жизни, а не
        // на демонстрационных 12,4 км.
        if args.contains("-demoHistory") {
            env.trip.seedDemoHistory(scale: args.contains("-demoBigNumbers") ? 20 : 1)
        }
        if args.contains("-demoMergePair") { env.trip.seedDemoMergePair() }
        // Обслуживание во всех состояниях (18.2): `-demoMaintenance` вместе с
        // `-showStats` (карточка в Итогах) или `-showSettings -settingsPage maintenance`.
        if args.contains("-demoMaintenance") { env.maintenance.seedDemo() }
        // Пришедшие штрафы поверх демо-истории — после её чтения: сверка
        // правит записи, а до чтения правка истории отклоняется.
        if args.contains("-demoFines") {
            Task {
                while !env.trip.isLoaded { await Task.pause(seconds: 0.2) }
                FineDemo.seed(env)
            }
        }
        // Машина и расходы (21.10): гибрид владельца, пустой или старый профиль.
        if args.contains("-demoEnergy") || args.contains("-demoEnergyLegacy") || args.contains("-demoEnergyBlank") {
            Task {
                while !env.trip.isLoaded { await Task.pause(seconds: 0.2) }
                EnergyDemo.seed(env, args: args)
            }
        }
        // С паузой: настоящие пробки приходят уже после загрузки карты, и
        // слой обязан перерисоваться на новом наборе, а не только на старте.
        if args.contains("-demoTraffic") {
            Task {
                await Task.pause(seconds: 3)
                env.traffic.seedDemo()
            }
        }
        // Снимки экранов для обзора вёрстки: -openScreen settings|search|
        // places|nearby|stats|camera|fines — открыть экран сразу после запуска.
        if let index = args.firstIndex(of: "-openScreen"), index + 1 < args.count {
            let screen = args[index + 1]
            Task {
                await Task.pause(seconds: 2)
                switch screen {
                case "settings": map.showSettings = true
                case "search": map.showSearch = true
                case "places": showMyPlaces = true
                case "nearby": map.showNearbySheet = true
                case "stats": map.showStats = true
                case "fines": showFines = true
                case "camera":
                    let here = env.location.currentCoordinate
                    map.selectedCamera = here.flatMap { env.cameras.nearest(to: $0, limit: 1).first } ?? env.cameras.cameras.first
                default: break
                }
            }
        }
        // Карточка объезда пробки — на снимок экрана без настоящей пробки.
        if args.contains("-demoDetour") {
            Task {
                await Task.pause(seconds: 3)
                env.route.seedDemoDetourOffer()
            }
        }
        // Погода на перевале — карточка и баннер машины на снимок без сервера.
        if args.contains("-demoRoadWeather") {
            Task {
                await Task.pause(seconds: 3)
                env.roadWeather.seedDemo()
            }
        }
        // Дорога на работу и домой: четыре недели будней поверх истории.
        if args.contains("-demoCommutes") {
            Task {
                // После чтения истории с диска: прочитанное позже вливается
                // поверх демо, и строки профиля не совпали бы с поездками.
                while !env.trip.isLoaded { await Task.pause(seconds: 0.2) }
                env.trip.seedDemoCommutes()
                env.commuteProfiles.seedDemo(home: TripStats.demoHome, work: TripStats.demoWork,
                                             trips: env.trip.history)
                env.refreshLearnedPlaces()
                // Учения призрака: профиль под скорость симулятора поверх демо
                // (дом и работа — выученные из демо-истории).
                if args.contains("-ghostDrill") {
                    env.commuteProfiles.seedDrill(home: TripStats.demoHome, work: TripStats.demoWork)
                }
            }
        }
        // Демо-история двухнедельной давности: проверка «в этом периоде поездок нет».
        if args.contains("-demoHistoryOld") { env.trip.seedDemoHistory(shiftDays: 14) }
        if args.contains("-showStats") { map.showStats = true }
        if args.contains("-showSettings") { map.showSettings = true }
        if args.contains("-showMyPlaces") { showMyPlaces = true }
        if args.contains("-showCameraDetail") {
            Task {
                await Task.pause(seconds: 1.5)
                if let coordinate = env.location.currentCoordinate,
                   let camera = env.cameras.nearest(to: coordinate, limit: 1).first {
                    map.select(camera)
                }
            }
        }
        // Детерминированный тест навигации: строим маршрут к фиксированной точке
        // Ташкента (просп. Амира Темура) от текущей позиции. С -driveDemo сразу
        // стартуем поездку (как «Поехали») — для прогонки движения по маршруту.
        // Повернуть карту (компас должен появиться): жестов у simctl нет.
        if args.contains("-rotateMap") {
            Task {
                // После snapToUserOnce (тот перебил бы позицию своим регионом).
                await Task.pause(seconds: 6)
                guard let center = env.location.currentCoordinate else { return }
                withMotion(.easeInOut(duration: 0.6)) {
                    map.position = .camera(MapCamera(centerCoordinate: center,
                                                     distance: 1200, heading: 45))
                }
            }
        }
        // Шеринг-карточки в PNG (Documents) — визуальная проверка без share-шита.
        if args.contains("-dumpShareCards") {
            Task {
                await Task.pause(seconds: 2)
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let last = env.trip.fallbackRecord(isTripActive: env.location.isTripActive)
                    ?? env.trip.history.first
                // Период берём тот, где данные ЕСТЬ: демо-история после
                // полуночи попадает в прошлую календарную неделю, и дамп
                // рисовал карточку из одних нулей (поймано на живом дампе).
                let period: StatsPeriod = .month
                let anchor = env.trip.history.first?.startedAt ?? Date()
                let summary = TripHistory.summary(days: env.trip.days, history: env.trip.history,
                                                  period: period, anchor: anchor)
                let passes = TripHistory.records(env.trip.history, period: period,
                                                 anchor: anchor).flatMap(\.passed)
                let tracks = TripHistory.records(env.trip.history, period: period, anchor: anchor)
                    .flatMap(\.trackPoints)
                let periodMap = await TripMapSnapshot.render(
                    track: tracks, passes: passes, size: CGSize(width: 1032, height: 420))
                let tripMap = await TripMapSnapshot.render(
                    track: last?.trackPoints ?? [], passes: last?.passed ?? [],
                    size: CGSize(width: 1032, height: 840))
                let badge = Achievements.all(for: env.trip.lifetime).first(where: \.earned)

                // Оба формата: сторис ломается иначе, чем лента, и увидеть
                // это нужно до отправки, а не у собеседника.
                for format in ShareFormat.allCases {
                    @MainActor func write(_ view: some View, _ name: String) {
                        let renderer = ImageRenderer(content: view)
                        renderer.scale = 2
                        renderer.proposedSize = ProposedViewSize(format.size)
                        do {
                            try renderer.uiImage?.pngData()?
                                .write(to: docs.appendingPathComponent("\(name)_\(format.rawValue).png"))
                        } catch {
                            Log.app.error("снимок карточки \(name, privacy: .public) не записан: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    write(PeriodShareCard(summary: summary, periodTitle: period.rangeTitle(containing: anchor),
                                          mapImage: periodMap, format: format), "share_stats")
                    if let record = last {
                        write(TripShareCard(record: record, mapImage: tripMap, format: format), "share_trip")
                    }
                    if let badge {
                        write(AchievementShareCard(badge: badge, lifetime: env.trip.lifetime,
                                                   format: format), "share_badge")
                    }
                }
            }
        }
        // Пикер типа отметки / тумблеры / вопрос «вы за рулём?» — для скриншотов.
        if args.contains("-reportPicker") {
            Task {
                await Task.pause(seconds: 3)
                if let coordinate = env.location.currentCoordinate ?? map.mapCenter {
                    withMotion { reportPoint = MapPoint(coordinate: coordinate) }
                }
            }
        }
        // Меню на карте (20.10): `-openQuickToggles` (старое имя `-quickToggles`)
        // и `-openLayers`. Закрываются сами через mapPopoverIdleSeconds — снимок
        // делать раньше.
        if args.contains("-quickToggles") || args.contains("-openQuickToggles") {
            Task {
                await Task.pause(seconds: 2)
                send(.toggle(.quickToggles))
            }
        }
        if args.contains("-openLayers") {
            Task {
                await Task.pause(seconds: 2)
                send(.toggle(.layers))
            }
        }
        // «Нет сигнала GPS» на снимок: фиксы в симуляторе не перестают идти сами.
        if args.contains("-demoNoSignal") {
            Task {
                await Task.pause(seconds: 3)
                env.location.isSignalStale = true
            }
        }
        if args.contains("-askDriver") {
            Task {
                await Task.pause(seconds: 2)
                env.notifications.askDriverCheck()
            }
        }
        // Умная тишина: демо-история даёт спокойные проезды одних и тех же
        // камер, после пересчёта у них появляется галочка «своя».
        if args.contains("-demoFamiliar") {
            Task {
                await Task.pause(seconds: 2)
                // Камеру берём без бейджа «неточная»: у него приоритет на
                // плече маркера, и галочку «своя» он бы перекрыл.
                guard let coordinate = env.location.currentCoordinate,
                      let camera = env.cameras.nearest(to: coordinate, limit: 12)
                          .first(where: { !$0.isApproximate })
                else { return }
                env.trip.seedDemoFamiliar(cameraID: camera.id, at: camera.coordinate)
                env.location.refreshFamiliarCameras()
                map.focus(on: camera)
            }
        }
        // Карточка «Поездка сохранена» — поверх карты, с демо-историей.
        if args.contains("-demoTripEnd") {
            Task {
                await Task.pause(seconds: 2)
                env.trip.seedDemoHistory()
                if let record = env.trip.history.first {
                    withMotion(.spring(duration: 0.4)) { tripEndRecord = record }
                }
            }
        }
        // Краудсорс-доверие: призрак + подтверждённая отметка и «Что это было?»
        // локально — настоящий POST с симулятора лёг бы фейком в общую базу.
        if args.contains("-demoMobileTrust") {
            Task {
                await Task.pause(seconds: 2)
                if let center = map.mapCenter ?? env.location.currentCoordinate {
                    withMotion { env.mobile.seedTrustDemo(near: center) }
                }
            }
        }
        // Память о треногах: подписанного файла на симуляторе нет, а зоны на
        // карте увидеть надо — сеем две точки локально.
        if args.contains("-demoHotspots") {
            Task {
                await Task.pause(seconds: 2)
                if let center = map.mapCenter ?? env.location.currentCoordinate {
                    env.hotspots.seedDemo(near: center)
                    withMotion { map.invalidateVisible() }
                }
            }
        }
        // Бар точки долгого тапа: жест на симуляторе из CLI не сымитировать.
        if args.contains("-mapMenu") {
            Task {
                await Task.pause(seconds: 3)
                if let center = map.mapCenter ?? env.location.currentCoordinate {
                    selectPoint(at: center)
                }
            }
        }
        // Дальняя поездка (19.3): настоящий маршрут до Самарканда (симулятор
        // ставят в Ташкент), демо-заведения вдоль него и статусы метана —
        // снимки карточки «Карта по пути» и листа «По пути» (-openAlong);
        // -driveDemo — поездка начата, машина стоит.
        if args.contains("-demoLongRoute") {
            Task {
                await Task.pause(seconds: 2)
                let name = env.settings.appLanguage == .uz ? "Samarqand" : "Самарканд"
                buildRoute(to: CLLocationCoordinate2D(latitude: 39.6542, longitude: 66.9597), name: name)
                for _ in 0..<60 where !env.route.isActive { await Task.pause(seconds: 0.5) }
                guard env.route.isActive else { return }
                let cng = env.corridor.seedDemoVenues(route: env.route).filter { $0.kind == .cng }
                let looks: [(CngStation.Status?, Int?, Bool)] = [(.gas, nil, true), (.nogas, nil, false), (.gas, 30, true)]
                env.cng.seedDemo(zip(cng, looks).map { venue, look in
                    CngStation(lat: venue.point.latitude, lon: venue.point.longitude, status: look.0,
                               statusAge: 40, queue: look.1, queueAge: look.1.map { _ in 10 }, confirmed: look.2)
                })
                // «Поехали» без касания: карточка в поездке, пока стоим.
                if args.contains("-driveDemo") {
                    await Task.pause(seconds: 1)
                    env.location.startTrip()
                }
                if args.contains("-openAlong") {
                    await Task.pause(seconds: 1.5)
                    showAlongRoute = true
                }
            }
        }
        // «Моя дорога» (24.4): выбор вариантов домой без сети.
        if args.contains("-demoMyRoad") {
            Task {
                // Холодный старт после загрузки симулятора: на 2 с маршрут
                // ложился раньше готовности экрана и не рисовался.
                await Task.pause(seconds: 4)
                if let rect = await MyRoadDemo.seed(env) { map.showRouteOverview(rect: rect) }
            }
        }
        if args.contains("-demoRoute") {
            Task {
                await Task.pause(seconds: 2)
                buildRoute(to: CLLocationCoordinate2D(latitude: 41.3260, longitude: 69.2810),
                           name: "Демо-маршрут")
                if args.contains("-driveDemo") {
                    await Task.pause(seconds: 3)
                    if env.route.isActive {
                        env.location.startTrip()   // ориентацию поставит onChange
                    }
                    // Автозавершение поездки через N секунд: на симуляторе нет
                    // CoreMotion (автостоп не сработает) и нет тапов — а для
                    // проверки Итогов/шеринга нужна завершённая запись в истории.
                    if let idx = args.firstIndex(of: "-endTripAfter"),
                       let seconds = args.dropFirst(idx + 1).first.flatMap(Double.init) {
                        await Task.pause(seconds: seconds)
                        env.location.endTrip()
                    }
                }
            }
        }
    }
    #endif
}
