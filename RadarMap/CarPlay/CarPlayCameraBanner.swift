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
//  iOS 27 (25.H1): аватар — значок типа цветом маркера, картинка над кнопкой —
//  знак ограничения у камеры и полоса приближения (CarPlayCameraBannerLook,
//  CarPlayBannerArt); крестика нет — закрывает «Понятно». Картинка
//  перерисовывается вместе с расстоянием, но только при смене ступени
//  полосы или знака. Раньше iOS 27 — как было: значок типа и строка лимита.
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
    /// `age` — подзаголовок отметки водителей с её возрастом (ReportAge.banner,
    /// 02.11: тренога — это «сейчас»): «Отметка водителей · 12 мин». Заголовок
    /// с расстоянием тот же; nil — камера базы или время неизвестно.
    static func text(name: String, kind: String, distance: String, limit: Int?,
                     age: [String]? = nil) -> Text {
        let limitText = limit.map {
            String(format: String(localized: "Ограничение %lld"), locale: .current, $0)
        }
        return Text(
            titles: [String(format: String(localized: "%1$@ через %2$@"), locale: .current, name, distance),
                     "\(name) · \(distance)",
                     distance],
            subtitles: age ?? [limitText.map { "\($0) · \(kind)" }, limitText, kind].compactMap { $0 })
    }

    /// Пора ли переписать баннер: цифра сменилась, и прошлое обновление было
    /// не меньше `interval` назад — каждое обновление — сообщение в машину.
    static func shouldUpdate(shown: Text?, new: Text, sinceLast: TimeInterval,
                             interval: TimeInterval = AppConfig.carPlayCameraBannerUpdateSeconds) -> Bool {
        shown != new && sinceLast >= interval
    }

    /// Держать ли баннер, когда тревога на миг пропала. `isApproachingCamera`
    /// мигает на шуме курса и точности: до 19.10 каждое мигание снимало
    /// баннер и показывало его снова — анимация и два сообщения в машину ради
    /// той же камеры. Та же камера и пропажа короче паузы — держим; другая
    /// камера или дольше паузы — снимаем.
    static func keepsThroughDropout(sameCamera: Bool, lostFor: TimeInterval,
                                    grace: TimeInterval = AppConfig.carPlayCameraBannerGraceSeconds) -> Bool {
        sameCamera && lostFor < grace
    }
}

extension CarPlayCameraCue {
    /// Решение по живому состоянию — одно для карты, баннера и оценок поездки.
    @MainActor
    static func current(_ location: LocationService) -> Cue {
        let id = location.nearestCamera?.id
        return decide(cameraID: id, approaching: location.isApproachingCamera,
                      familiar: id.map { location.familiarCameraIDs.contains($0) } ?? false)
    }

    /// «0 м» о проехавшей камере по живому состоянию (`isProvenPassedZero`).
    /// Только показ; `current` и всё, что его читает, этого не знают.
    @MainActor
    static func passedZero(_ location: LocationService, camera: Camera, distance: Double) -> Bool {
        // Дешёвое первым: почти на всех тиках расстояние не ноль.
        guard distance < AppConfig.carPlayGaugeZeroMeters, let coordinate = location.currentCoordinate else {
            passedHold = PassedZeroHold()
            return false
        }
        let situation = location.gateSituation(at: coordinate)
        let proven = isProvenPassedZero(distance: distance, camera: camera, in: situation,
                                        positionCoarse: location.isPositionCoarse)
        let straight = GeoMath.fastDistance(coordinate.latitude, coordinate.longitude, camera.lat, camera.lon)
        return passedHold.update(cameraID: camera.id, distance: distance, straight: straight, proven: proven,
                                 clearlyAhead: LocationGates.isClearlyAhead(camera, in: situation))
    }

    /// Одно удержание на баннер, подпись и строку оценок: иначе миг без курса
    /// вернул бы «0 м» подписи при снятом баннере.
    @MainActor private static var passedHold = PassedZeroHold()

    @MainActor static func resetPassedHold() { passedHold = PassedZeroHold() }
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
    /// Картинка баннера на iOS 27 (знак, ступень полосы) и тема, под которую
    /// она нарисована, — что ушло последним.
    private var shownArt: CarPlayCameraBannerLook.Art?
    private var shownArtDark: Bool?
    /// Пределы картинок баннера (iOS 27) — спрашиваем систему один раз за
    /// подключение, не на пути тревоги (ARCHITECTURE.md, правило 21).
    private var imageSizes: (avatar: CGSize, alert: CGSize)?
    private var updatedAt = Date.distantPast
    /// Ограничение у камеры — одно на подъезд: поиск по индексу дорог на
    /// каждом тике ради сравнения строк не нужен.
    private var limit: (cameraID: Int, value: Int?)?
    /// Когда тревога пропала при показанном баннере (пауза до снятия).
    private var lostSince: Date?
    /// Снятие по истечении паузы. Само `update` по времени не перезапустится:
    /// его зовёт наблюдение, а без маршрута и без новых фиксов наблюдать
    /// нечего — баннер (`duration: 0`) висел бы до смены ближайшей камеры.
    private var graceTask: Task<Void, Never>?
    private var env: AppEnvironment { .shared }

    func update(banners: CarPlayBanners, onScreen: Bool, onDark: Bool) {
        let location = env.location
        // Тревога гейтов (в радиусе = уровень ≥ 1, скорость от
        // directionalMinSpeedKmh) — баннер; своя камера — без баннера: голос о
        // ней молчит, и на карте у неё галочка (CarPlayCameraCue).
        let passed = location.nearestCamera.flatMap { camera in
            location.distanceToNearest.map { CarPlayCameraCue.passedZero(location, camera: camera, distance: $0) }
        } ?? false
        guard CarPlayCameraCue.current(location).banner, let camera = location.nearestCamera,
              let distance = location.distanceToNearest, !passed else {
            // Проехали или тревога снята: баннер уходит, следующий подъезд —
            // заново, в том числе к той же камере. Короткое мигание тревоги
            // у той же камеры баннер не трогает.
            if let alert {
                let now = Date()
                let since = lostSince ?? now
                lostSince = since
                // Доказанный проезд снимается сразу: пауза только от мигания тревоги.
                if !passed, CarPlayCameraBannerText.keepsThroughDropout(
                    sameCamera: location.nearestCamera?.id == cameraID,
                    lostFor: now.timeIntervalSince(since)) {
                    if graceTask == nil {
                        graceTask = Task { @MainActor [weak self, weak banners] in
                            await Task.pause(seconds: AppConfig.carPlayCameraBannerGraceSeconds)
                            guard !Task.isCancelled, let self, self.alert === alert,
                                  self.lostSince != nil else { return }
                            banners?.dismiss(alert)
                            self.clear()
                        }
                    }
                    return
                }
            }
            if let alert { banners.dismiss(alert) }
            clear()
            return
        }
        lostSince = nil
        graceTask?.cancel()
        graceTask = nil

        if let alert, cameraID == camera.id {
            let showing = banners.isShowing(alert)
            if showing, presentedOnScreen == onScreen {
                // Тот же подъезд — переписать цифру. Дешёвое первым: тик GPS
                // приходит чаще, чем баннеру можно меняться.
                let since = Date().timeIntervalSince(updatedAt)
                guard since >= AppConfig.carPlayCameraBannerUpdateSeconds else { return }
                let text = text(for: camera, distance: distance)
                let art = art(for: camera, distance: distance)
                let textChanged = CarPlayCameraBannerText.shouldUpdate(shown: shownText, new: text, sinceLast: since)
                let artChanged = art != nil && (art != shownArt || onDark != shownArtDark)
                guard textChanged || artChanged else { return }
                if #available(iOS 27.0, *), artChanged, let art {
                    // Картинка — вместе с цифрой одним сообщением; кнопки те же,
                    // срок прежний (-1 — «не менять», CPNavigationAlert.h).
                    let images = images(for: camera, art: art, onDark: onDark)
                    alert.updateTitleVariants(text.titles, subtitleVariants: text.subtitles,
                                              avatarImage: images.avatar, alert: images.alert,
                                              actions: alert.actions, duration: -1)
                    shownArt = art
                    shownArtDark = onDark
                } else {
                    alert.updateTitleVariants(text.titles, subtitleVariants: text.subtitles)
                }
                shownText = text
                updatedAt = Date()
                return
            }
            // Закрыт водителем — о той же камере не напоминаем; истёк на том
            // же экране — тоже. Экран сменился (вернулись к RadarMap после
            // истёкшего уведомления, ушли в музыку) — показываем заново.
            if !showing, banners.wasClosedByDriver(alert) || presentedOnScreen == onScreen { return }
        }

        let text = text(for: camera, distance: distance)
        let art = art(for: camera, distance: distance)
        // На нашем экране — до конца подъезда (снимаем сами); поверх чужого
        // приложения — уведомление, как до 18.10.
        let duration = onScreen ? 0 : AppConfig.carPlayCameraAlertSeconds
        let understood = CPAlertAction(title: String(localized: "Понятно"), style: .cancel) { _ in }
        let next: CPNavigationAlert
        if #available(iOS 27.0, *), let art {
            let images = images(for: camera, art: art, onDark: onDark)
            next = CPNavigationAlert(titleVariants: text.titles, subtitleVariants: text.subtitles,
                                     avatarImage: images.avatar, alert: images.alert,
                                     actions: [understood], duration: duration)
            // Закрывает «Понятно»; второй крестик рядом с ним — лишняя цель
            // для пальца на ходу.
            next.showsCloseButton = false
        } else {
            next = CPNavigationAlert(
                titleVariants: text.titles,
                subtitleVariants: text.subtitles,
                image: CarPlayGuidance.symbol(camera.kind.symbolName, pointSize: 30, onDark: onDark),
                primaryAction: understood,
                secondaryAction: nil,
                duration: duration)
        }
        // Прежний баннер не снимаем отдельно: камера заменяет всё, и замену
        // делает очередь — два снятия подряд CarPlay мог бы сложить так, что
        // новый баннер не встал бы вовсе.
        alert = nil
        guard banners.show(next, kind: .camera) else { return }
        alert = next
        cameraID = camera.id
        presentedOnScreen = onScreen
        shownText = text
        shownArt = art
        shownArtDark = onDark
        updatedAt = Date()
        Log.carplay.notice("камера \(camera.id, privacy: .public): баннер \(onScreen ? "на нашем экране" : "поверх другого приложения", privacy: .public)")
    }

    private func text(for camera: Camera, distance: Double) -> CarPlayCameraBannerText.Text {
        if limit?.cameraID != camera.id {
            limit = (camera.id, env.speedLimits.limit(near: camera.coordinate))
        }
        // Минуты отметки обновляются вместе с расстоянием (не чаще раза в
        // секунду, shouldUpdate) — отдельного таймера баннеру не нужно.
        // Свежесть (82): «Подтвердили 3 мин назад» / «Не подтверждали 50 мин».
        let age = camera.mobileFresh.flatMap { TripodFreshness.banner($0, now: Date()) }
            ?? env.mobile.confirmation(for: camera.id).flatMap {
            ReportAge.banner(created: $0.created, confirmed: $0.confirmed, now: Date())
        }
        return CarPlayCameraBannerText.text(name: camera.kind.shortName, kind: camera.kind.displayName,
                                            distance: Formatting.distance(distance),
                                            limit: limit?.value, age: age)
    }

    /// Картинка баннера — только на iOS 27 (раньше у баннера её нет).
    private func art(for camera: Camera, distance: Double) -> CarPlayCameraBannerLook.Art? {
        guard #available(iOS 27.0, *) else { return nil }
        if limit?.cameraID != camera.id {
            limit = (camera.id, env.speedLimits.limit(near: camera.coordinate))
        }
        return CarPlayCameraBannerLook.art(limit: limit?.value, distance: distance,
                                           radius: env.location.effectiveAlertRadius)
    }

    /// Пределы картинок баннера — при подключении (CarPlayGuidance.attach), а
    /// не лениво внутри первой тревоги: обращения к системе за пределами —
    /// не на пути оповещения (правило 21).
    func prepare() {
        guard #available(iOS 27.0, *) else { return }
        _ = bannerImageSizes()
    }

    @available(iOS 27.0, *)
    private func bannerImageSizes() -> (avatar: CGSize, alert: CGSize) {
        if let imageSizes { return imageSizes }
        let sizes = (
            avatar: CarPlayCameraBannerLook.fit(AppConfig.carPlayBannerAvatarSize,
                                                into: CPNavigationAlert.maximumAvatarImageSize),
            alert: CarPlayCameraBannerLook.fit(AppConfig.carPlayBannerAlertImageSize,
                                               into: CPNavigationAlert.maximumAlertImageSize))
        imageSizes = sizes
        Log.carplay.notice("баннер камеры iOS 27: аватар \(Int(sizes.avatar.width), privacy: .public)×\(Int(sizes.avatar.height), privacy: .public), картинка \(Int(sizes.alert.width), privacy: .public)×\(Int(sizes.alert.height), privacy: .public) (предел \(Int(CPNavigationAlert.maximumAlertImageSize.width), privacy: .public)×\(Int(CPNavigationAlert.maximumAlertImageSize.height), privacy: .public)), кнопок до \(CPNavigationAlert.maximumActionsCount, privacy: .public)")
        return sizes
    }

    @available(iOS 27.0, *)
    private func images(for camera: Camera, art: CarPlayCameraBannerLook.Art,
                        onDark: Bool) -> (avatar: UIImage, alert: UIImage) {
        let sizes = bannerImageSizes()
        return (CarPlayBannerArt.avatar(camera.kind, size: sizes.avatar),
                CarPlayBannerArt.alertImage(art, type: camera.kind, size: sizes.alert, onDark: onDark))
    }

    /// Подключение кончилось.
    func reset() {
        clear()
        CarPlayCameraCue.resetPassedHold()
        imageSizes = nil   // другая машина — другие пределы
    }

    private func clear() {
        alert = nil
        cameraID = nil
        shownText = nil
        shownArt = nil
        shownArtDark = nil
        updatedAt = .distantPast
        limit = nil
        lostSince = nil
        graceTask?.cancel()
        graceTask = nil
    }
}
