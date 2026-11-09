//
//  MapScreen+ActionBar.swift
//  RadarMap
//
//  Главный экран: нижняя панель действий, кнопка поездки, меню «…», баннеры.
//

import SwiftUI
import MapKit
import CoreLocation
import UIKit

extension MapScreen {

    /// «Начать поездку» там, где без нажатия поездки не будет вовсе (ручной
    /// старт): та же главная кнопка, что «Поехали» и «Отправить», — жёлтая
    /// PrimaryButton над доком. Где поездка начнётся и сама, отдельной кнопки
    /// нет: старт — пятая кнопка дока (`tripStartsByItself`).
    var tripButtonPrimary: some View {
        PrimaryButton(title: "Начать поездку", systemImage: "play.fill") { toggleTrip() }
            .liftAccent()
    }

    /// Поездка начнётся сама (автостарт или «умный»): кнопка старта —
    /// запасной выход, ей место в доке, а не крик над картой.
    var tripStartsByItself: Bool {
        TripStartPrompt.prominence(startsByItself: env.settings.tripStartMode.usesMotion) == .secondary
    }

    /// Док главного экрана (этап 45, вариант A, выбор владельца 05.11):
    /// поле «Куда едем?» и квадрат «Итоги», под ними чипы «Домой» / «На
    /// работу» и звезда «Мои места» (IdleDock). Поиск, «Рядом», «Добавить
    /// камеру» и Настройки — плитки круга «…» в колонке справа, те же, что в
    /// поездке. При ручном старте над доком — жёлтая «Начать поездку»; где
    /// поездка начнётся сама, запасной старт — круг ▶ в строке чипов.
    var actionBar: some View {
        IdleDock(onSearch: { map.showSearch = true },
                 onStats: { map.showStats = true },
                 onRoute: { coordinate, name in buildRoute(to: coordinate, name: name) },
                 onMyPlaces: { showMyPlaces = true },
                 onStartTrip: tripStartsByItself ? { toggleTrip() } : nil)
    }

    @ViewBuilder var permissionBanner: some View {
        if let banner = bannerInfo {
            // Та же форма, что у баннеров состояния (5.10); без крестика —
            // без доступа приложение не делает главного.
            StatusBanner(symbol: "exclamationmark.triangle.fill", tint: Theme.warning,
                         title: banner.message,
                         action: StatusBanner.Action(title: banner.button, perform: banner.action))
        }
    }

    @ViewBuilder var loadErrorOverlay: some View {
        if let error = env.loadError {
            ContentUnavailableView("Не удалось загрузить камеры",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        }
    }

    // MARK: - Действия

    func addCamera(kind: AddKind, name: String) {
        guard let center = map.mapCenter else {
            withMotion { map.isAddingCamera = false }
            return
        }
        let type: CameraType = kind == .radar ? .stationaryRadar : .stationaryCamera
        env.cameras.addCamera(at: center, type: type, label: name)   // revision → onChange обновит карту
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withMotion { map.isAddingCamera = false }
    }

    var bannerInfo: (message: String, button: String, action: () -> Void)? {
        // Приблизительная — первой: без точной фиксы отбрасываются, и оповещений
        // нет ни при каком уровне доступа.
        if env.location.isAuthorized && !env.location.hasFullAccuracy {
            return (String(localized: "Включите точную геолокацию, иначе оповещения не сработают."),
                    String(localized: "Включить точную"), { env.location.requestPreciseLocation() })
        }
        switch env.location.authorizationStatus {
        case .notDetermined:
            return (String(localized: "Разрешите геолокацию — без неё не будет оповещений о камерах."),
                    String(localized: "Разрешить"), { env.location.takeAccessStep() })
        case .denied, .restricted:
            if !env.location.locationServicesOn {
                return (String(localized: "Службы геолокации выключены: Настройки → Конфиденциальность → Службы геолокации."),
                        String(localized: "Настройки"), openSettings)
            }
            return (String(localized: "Геолокация выключена. Включите «Всегда» для оповещений о камерах."),
                    String(localized: "Настройки"), openSettings)
        case .authorizedWhenInUse:
            // Через потерю, а не выгоду (40D). «До поездки» — правда: поездка,
            // начатая на экране, звучит и в фоне (S2), молчит свёрнутое или
            // погашенное заранее.
            // Кнопка — тот же шаг, что в онбординге: окно iOS, пока его ещё
            // покажут, потом Настройки.
            return (String(localized: "Свернёте или погасите экран до поездки — о камерах промолчу. Нужен доступ «Всегда»."),
                    String(localized: "Включить"), { env.location.takeAccessStep() })
        default:
            break
        }
        if env.notifications.authorizationStatus == .denied {
            return (String(localized: "Уведомления выключены — вы не услышите сигнал о камере."),
                    String(localized: "Настройки"), openSettings)
        }
        return nil
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
