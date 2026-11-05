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

    /// Док главного экрана — ОДНА панель (этап 31, вариант A, выбор
    /// владельца 26.10). Раньше низ был тремя формами друг над другом:
    /// карточка «Домой», висящая над картой капсула «Начать поездку» и
    /// четыре кнопки — на SE ≈ 330 pt из 667. Теперь подсказка «Домой» —
    /// верхней строкой этой же панели, старт поездки — пятой кнопкой, и низ
    /// занимает ≈ 150 pt.
    ///
    /// Редкое «добавить свою камеру» и «Рядом» живут в «Ещё» (plan_main_screen.md, шаг 4).
    var actionBar: some View {
        VStack(spacing: 0) {
            if dockShowsSuggestion {
                DestinationSuggestionBar { coordinate, name in
                    buildRoute(to: coordinate, name: name)
                }
            }
            // По верху: на крупном шрифте подпись может уйти в две строки
            // (ActionBarLabel), и значки соседей не должны съезжать вниз.
            HStack(alignment: .top, spacing: 0) {
                actionButton("Поиск", "magnifyingglass") { map.showSearch = true }
                // «Мои места» — на месте спидометра, который владелец попросил
                // убрать. Дорога домой или на работу — самое частое, что
                // навигатор делает одним тапом; у Яндекса и Amap «Мои места»
                // живут ровно здесь.
                actionButton("Мои места", Icon.myPlaces) { showMyPlaces = true }
                actionButton("Итоги", "chart.bar.fill") { map.showStats = true }
                if tripStartsByItself {
                    actionButton("Поездка", "play.fill", touch: .primary) { toggleTrip() }
                        .accessibilityLabel(Text("Начать поездку"))
                }
                Menu {
                    moreActionItems
                } label: {
                    ActionBarLabel(title: "Ещё", icon: "ellipsis")
                }
                .accessibilityLabel(Text("Ещё"))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        // Сплошная панель, а не стекло (решение 13.10): карта под баром в
        // покое всё равно живёт, и стекло пересчитывало размытие на каждом её
        // кадре; к тому же сквозь него просвечивали подписи улиц.
        .liftedBackground(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous)
            .strokeBorder(Theme.edgePanel, lineWidth: 1))
    }

    /// Редкое: в баре место занимало бы всегда, а нужно раз в месяц.
    @ViewBuilder var moreActionItems: some View {
        // «Рядом» переехал сюда из бара. Не удалён: список с расстояниями
        // иногда удобнее карты — например, пассажиру или когда карта ещё
        // грузится. Но постоянного места он не заслуживает, потому что
        // отвечает на тот же вопрос, что и карта под ним.
        Button { map.showNearbySheet = true } label: {
            Label("Рядом", systemImage: "list.bullet")
        }
        Button {
            withMotion { map.isAddingCamera = true }
        } label: {
            Label("Добавить камеру", systemImage: Icon.ownCamera)
        }
        Button { map.showSettings = true } label: {
            Label("Настройки", systemImage: "gearshape.fill")
        }
    }

    func actionButton(_ title: LocalizedStringKey, _ icon: String, touch: TouchRole = .regular,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ActionBarLabel(title: title, icon: icon)
        }
        .buttonStyle(PressableStyle(touch))
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
        switch env.location.authorizationStatus {
        case .denied, .restricted:
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
        if env.location.isAuthorized && !env.location.hasFullAccuracy {
            return (String(localized: "Включена приблизительная геолокация — оповещения о камерах будут неточными."),
                    String(localized: "Включить точную"), { env.location.requestPreciseLocation() })
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

/// Подпись кнопки дока: значок и слово под ним.
///
/// Значок — в рамке ОДНОЙ высоты: у звезды, лупы и столбиков разные поля, и
/// подписи стояли на разной высоте («Мои места» на 6 px ниже «Итогов»,
/// снимок этапа 31). «Ещё» — голое многоточие, как остальные значки: залитый
/// круг был единственным значком другого веса.
///
/// Подпись — до двух строк: «Mening joylarim» в пятой части ширины SE не
/// помещается, а ужатая до 0,75 была мельче соседей (снимок этапа 31). Две
/// строки только у неё; ряд выровнен по верху, и значки соседей стоят на месте.
struct ActionBarLabel: View {
    let title: LocalizedStringKey
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.rounded(19, .semibold))
                .frame(height: 26)
            Text(title)
                .font(.rounded(12, .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.9)
        }
        .foregroundStyle(Theme.textPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
