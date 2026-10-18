//
//  CarPlayCameraBanner.swift
//  RadarMap
//
//  Камера впереди на экране машины — системным баннером навигатора.
//
//  До 18.10 баннер показывался, только когда на экране машины ДРУГОЕ
//  приложение. На нашем о камере говорила плашка в правом нижнем углу, и
//  главная функция приложения в машине была почти не видна (аудит 18.10,
//  п. 2). Баннер — штатный способ CarPlay сказать о событии на дороге
//  (CPNavigationAlert), и теперь он есть всегда:
//  • на нашем экране — весь подъезд, расстояние в нём идёт вниз
//    (updateTitleVariants), снимается, когда камеру проехали;
//  • поверх другого приложения — уведомление на carPlayCameraAlertSeconds,
//    как раньше: длительность уведомления решает система.
//  Решение «предупреждать ли» по-прежнему принимают гейты оповещений: баннер
//  говорит ровно о той камере, о которой говорит голос и док.
//

import CarPlay
import os

/// Тексты баннера. Без UIKit — покрыто CarPlayCameraBannerTests.
nonisolated enum CarPlayCameraBannerText {

    struct Text: Equatable, Sendable {
        let titles: [String]
        let subtitles: [String]
    }

    /// Варианты — от длинного к короткому: машина берёт первый, что влезет.
    /// Расстояние есть в каждом заголовке: иначе на узком экране баннер
    /// говорил бы «Камера» без самого важного.
    static func text(name: String, kind: String, distance: String, limit: Int?) -> Text {
        let limitText = limit.map {
            String(format: String(localized: "Ограничение %lld"), locale: .current, $0)
        }
        return Text(
            titles: [String(format: String(localized: "%1$@ через %2$@"), locale: .current, name, distance),
                     "\(name) · \(distance)",
                     distance],
            subtitles: [limitText.map { "\($0) · \(kind)" }, limitText, kind].compactMap { $0 })
    }

    /// Пора ли переписать баннер: цифра сменилась, и прошлое обновление было
    /// не меньше `interval` назад — каждое обновление — сообщение в машину.
    static func shouldUpdate(shown: Text?, new: Text, sinceLast: TimeInterval,
                             interval: TimeInterval = AppConfig.carPlayCameraBannerUpdateSeconds) -> Bool {
        shown != new && sinceLast >= interval
    }
}

/// Баннер камеры одного подключения. Зовётся на каждом пересчёте ведения.
@MainActor
final class CarPlayCameraBanner {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    private var alert: CPNavigationAlert?
    private var cameraID: Int?
    /// Баннер показан на нашем экране (висит весь подъезд) или поверх чужого
    /// приложения (уведомление на несколько секунд).
    private var presentedOnScreen = false
    private var shownText: CarPlayCameraBannerText.Text?
    private var updatedAt = Date.distantPast

    private var env: AppEnvironment { .shared }

    func update(banners: CarPlayBanners, onScreen: Bool, onDark: Bool) {
        let location = env.location
        guard location.isApproachingCamera, let camera = location.nearestCamera,
              let distance = location.distanceToNearest else {
            // Проехали или тревога снята: баннер уходит, следующий подъезд —
            // заново, в том числе к той же камере.
            if let alert { banners.dismiss(alert) }
            clear()
            return
        }
        let text = CarPlayCameraBannerText.text(
            name: camera.kind.shortName, kind: camera.kind.displayName,
            distance: Formatting.distance(distance),
            limit: env.speedLimits.limit(near: camera.coordinate))

        if let alert, cameraID == camera.id {
            // Закрыли «Понятно» или истекло — о той же камере не напоминаем.
            guard banners.isShowing(alert) else { return }
            if presentedOnScreen == onScreen {
                guard CarPlayCameraBannerText.shouldUpdate(shown: shownText, new: text,
                                                           sinceLast: Date().timeIntervalSince(updatedAt))
                else { return }
                alert.updateTitleVariants(text.titles, subtitleVariants: text.subtitles)
                shownText = text
                updatedAt = Date()
                return
            }
            // Водитель ушёл с нашего экрана или вернулся посреди подъезда:
            // длительность баннера другая — показать заново.
            banners.dismiss(alert)
        } else if let alert {
            banners.dismiss(alert)   // следующая камера сменила прежнюю
        }

        let next = CPNavigationAlert(
            titleVariants: text.titles,
            subtitleVariants: text.subtitles,
            image: CarPlayGuidance.symbol(camera.kind.symbolName, pointSize: 30, onDark: onDark),
            primaryAction: CPAlertAction(title: String(localized: "Понятно"), style: .cancel) { _ in },
            secondaryAction: nil,
            // На нашем экране — до конца подъезда (снимаем сами); поверх
            // чужого приложения — уведомление, как до 18.10.
            duration: onScreen ? 0 : AppConfig.carPlayCameraAlertSeconds)
        clear()
        guard banners.show(next, kind: .camera) else { return }
        alert = next
        cameraID = camera.id
        presentedOnScreen = onScreen
        shownText = text
        updatedAt = Date()
        Log.carplay.notice("камера \(camera.id, privacy: .public): баннер \(onScreen ? "на нашем экране" : "поверх другого приложения", privacy: .public)")
    }

    /// Подключение кончилось.
    func reset() { clear() }

    private func clear() {
        alert = nil
        cameraID = nil
        shownText = nil
        updatedAt = .distantPast
    }
}
