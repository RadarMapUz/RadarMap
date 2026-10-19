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

    /// «Начать поездку»: громкость кнопки решает правило, а не вёрстка.
    @ViewBuilder
    var tripButton: some View {
        switch TripStartPrompt.prominence(
            startsByItself: env.settings.tripStartMode.usesMotion) {
        case .primary:   tripButtonPrimary
        case .secondary: tripButtonSecondary
        }
    }

    /// Запасной выход там, где поездка начнётся и без него. Язык тот же, что у
    /// «Я пассажир»: серый текст на Theme.surface — видно, но не кричит.
    var tripButtonSecondary: some View {
        Button {
            toggleTrip()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.fill").font(.rounded(11, .semibold))
                Text("Начать поездку").font(.rounded(13, .semibold))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.controlSize)
            .background(Theme.surface, in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    /// CTA для тех, у кого автостарт выключен: без нажатия поездки не будет
    /// вовсе. Та же главная кнопка, что «Поехали» и «Отправить» — жёлтая
    /// PrimaryButton; был зелёный градиент-капсула, третий облик одной роли.
    var tripButtonPrimary: some View {
        PrimaryButton(title: "Начать поездку", systemImage: "play.fill") { toggleTrip() }
            .liftAccent()
    }

    /// Док действий: стекло со световой кромкой и глубокая тень — в одном
    /// языке с CTA и кругами (премиальный низ экрана без разнобоя).
    /// Четыре постоянных действия — больше глазу не нужно. Редкое «добавить
    /// свою камеру» живёт в меню «Ещё»: оно нужно раз в месяц, а место в баре
    /// занимало всегда (plan_main_screen.md, шаг 4).
    var actionBar: some View {
        HStack(spacing: 4) {
            actionButton("Поиск", "magnifyingglass") { map.showSearch = true }
            // «Мои места» — на месте спидометра, который владелец попросил
            // убрать («мне кажется не нужен»). Дорога домой или на работу —
            // самое частое, что навигатор делает одним тапом; у Яндекса и
            // Amap «Мои места» живут ровно здесь. Раньше Дом и Работа были
            // строкой внутри «Поиска», то есть в двух тапах и под клавиатурой.
            //
            // «Рядом» сюда не вернулся по прежней причине: список камер
            // поблизости открывался с экрана, который эти же камеры уже
            // показывает на карте, — он живёт в «Ещё».
            actionButton("Мои места", Icon.myPlaces) { showMyPlaces = true }
            actionButton("Итоги", "chart.bar.fill") { map.showStats = true }
            Menu {
                moreActionItems
            } label: {
                actionLabel("Ещё", "ellipsis.circle.fill")
            }
            .accessibilityLabel(Text("Ещё"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        // Сплошная панель, а не стекло (решение 13.10): карта под баром в
        // покое всё равно живёт — тайлы, «я», слежение, — и стекло
        // пересчитывало размытие на каждом её кадре; к тому же сквозь него
        // просвечивали подписи улиц под подписями кнопок (снимок 12.10).
        // Та же поверхность, что у панели поездки и HUD.
        .liftedBackground(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous)
            .strokeBorder(Theme.edgePanel, lineWidth: 1))
    }

    /// Пункты меню поездки — то, что нужно В ДОРОГЕ (5.3): куда ехать, что
    /// впереди, кому сказать время прибытия. «Итоги», «Настройки» и «Добавить
    /// камеру» — экраны на минуту чтения или прицел на карте: в меню они
    /// появляются, только когда стоим (нижнего бара в поездке нет).
    @ViewBuilder var tripActionItems: some View {
        Button { map.showSearch = true } label: {
            Label("Поиск", systemImage: "magnifyingglass")
        }
        Button { showMyPlaces = true } label: {
            Label("Мои места", systemImage: Icon.myPlaces)
        }
        // Число камер впереди иначе не видно нигде, кроме капсулы на подходе.
        if env.route.isActive {
            Button { showRouteCameras = true } label: {
                Label("Камеры на маршруте", systemImage: Icon.cameras)
            }
        }
        // Время прибытия знакомому — пока идёт маршрут (EtaShareService).
        if env.etaShare.isSharing {
            Button { env.etaShare.stop() } label: {
                Label("Перестать делиться прибытием", systemImage: "person.crop.circle.badge.xmark")
            }
        } else if env.etaShare.isAvailable {
            Button { shareArrival() } label: {
                Label("Поделиться прибытием", systemImage: "square.and.arrow.up")
            }
        }
        Button { map.showNearbySheet = true } label: {
            Label("Рядом", systemImage: "list.bullet")
        }
        if TripScreenLayout.tripMenuShowsParkedItems(speedKmh: env.location.speedKmh) {
            Section {
                Button { map.showStats = true } label: {
                    Label("Итоги", systemImage: "chart.bar.fill")
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
        }
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

    func actionButton(_ title: LocalizedStringKey, _ icon: String, tint: Color = Theme.textPrimary,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionLabel(title, icon, tint: tint)
        }
        .buttonStyle(PressableStyle())
    }

    /// Общая разметка кнопки бара — её же носит меню «Ещё».
    func actionLabel(_ title: LocalizedStringKey, _ icon: String,
                             tint: Color = Theme.textPrimary) -> some View {
        VStack(spacing: 5) {
                Image(systemName: icon).font(.rounded(19, .semibold))
                Text(title)
                    .font(.rounded(10, .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
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
            return (String(localized: "Для фоновых оповещений выберите доступ «Всегда»."),
                    String(localized: "Настройки"), openSettings)
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
