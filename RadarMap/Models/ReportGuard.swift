//
//  ReportGuard.swift
//  RadarMap
//
//  Когда отметку водителя МОЖНО отправить, а когда она — дубль.
//
//  Кнопка «Радар!» сделана для одного тапа на скорости, вслепую, большим
//  пальцем. Значит по ней будут промахиваться, жать дважды «на всякий случай»
//  и нажимать снова через квартал, проезжая тот же пост. Каждый такой тап —
//  запись в общей базе, которую увидят все: пять отметок вместо одной
//  превращают одного гаишника в засаду на километр.
//
//  Правило простое и несимметричное: **сомневаешься — не отправляй**. Лишняя
//  отметка портит карту всем, пропущенная стоит одного неотмеченного радара,
//  и второй водитель через минуту отметит его снова. Поэтому гасим и по
//  времени, и по расстоянию, и по типу.
//
//  Проверка на стоянке — отдельный случай, и она НЕ про дубли: отметка без
//  движения обычно ставится дома «чтобы проверить, как работает». Сервер её
//  примет, а на карте появится радар посреди двора.
//
//  Чистая логика, покрыта ReportGuardTests.
//

import CoreLocation
import Foundation

nonisolated enum ReportGuard {

    /// Отметка, которую уже отправили.
    struct Sent: Equatable {
        var kind: ReportKind
        var latitude: Double
        var longitude: Double
        var at: Date
        /// Серверный id этой точки: уточнение и отзыв идут ровно в неё, а не в
        /// «последнюю отправленную» — ту могла подменить досылка из очереди.
        var serverID: Int? = nil

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// Почему нельзя. Каждая ветка обязана уметь объяснить себя водителю:
    /// молчащая кнопка читается как сломанная.
    enum Refusal: Equatable {
        /// Нет достоверного положения — ставить отметку не по чему.
        case noPosition
        /// Тот же радар уже отмечен только что.
        case duplicate
        /// Стоим — скорее всего это проверка «а как работает», а не засада.
        case notDriving
    }

    /// Сколько времени и метров вокруг прошлой отметки того же типа считаем
    /// повтором. Три минуты — обычная длина «а вдруг не нажалось»; 400 м —
    /// столько проезжаешь за это время в городе, и в пределах этого расстояния
    /// пост наверняка тот же.
    static let duplicateWindowSeconds: TimeInterval = 180
    static let duplicateRadiusMeters: CLLocationDistance = 400

    /// Откуда взялась координата отметки — от этого зависит проверка на стоянке.
    ///
    /// `blind` — кнопка, CarPlay, Siri: точка взята из GPS, водитель на экран
    /// не смотрел. Здесь проверка на стоянке и нужна: тап из кресла дома
    /// рождает радар посреди двора.
    ///
    /// `deliberate` — долгое нажатие на карте и прицел в «Ещё»: человек
    /// показал пальцем конкретное место и выбрал тип из списка. Это ровно то,
    /// что делают, стоя на обочине или уже приехав, — глушить такую отметку
    /// нечестно, она осмысленнее слепого тапа. Защита от дублей, дневной
    /// счётчик и очередь без сети остаются те же.
    enum Placement {
        case blind
        case deliberate
    }

    /// Насколько можно верить своей точке для слепой отметки.
    ///
    /// `currentCoordinate` пишет не только принятый фикс: при долгом браке
    /// (телефон под стеклом, сотовые 100–300 м) туда ложится грубая точка для
    /// картинки, а в тихом фоне — фикс значимого перемещения, сделанный, может
    /// быть, километры назад. Отметка по такой точке встаёт в сотнях метров от
    /// засады — у всех, — а там, где тренога стоит на самом деле, её нет.
    struct Fix: Equatable {
        /// Точка из отброшенного фильтром фикса (`isPositionCoarse`).
        var isCoarse: Bool
        /// Сторож сигнала: едем, а фиксов нет дольше нормы.
        var isSignalStale: Bool
        /// Погрешность последнего принятого фикса, м; ≤ 0 — неизвестна.
        var accuracy: Double
        /// Сколько секунд назад принят последний годный фикс; nil — не было.
        var age: TimeInterval?
        /// Непрерывный GPS (поездка, открытый экран, машина). Стоя фиксы не
        /// приходят из-за фильтра расстояния, и минутной давности фикс в пробке
        /// у поста — ещё правда; в тихом фоне — нет.
        var isContinuous: Bool
    }

    /// Годится ли точка для слепой отметки. Сомневаешься — не отправляй:
    /// «Ждём спутники» стоит одного повторного нажатия, точка не там — карты
    /// всех, кто едет следом.
    static func isTrusted(_ fix: Fix) -> Bool {
        guard !fix.isCoarse, !fix.isSignalStale, let age = fix.age else { return false }
        if fix.accuracy > AppConfig.reportMaxFixAccuracyMeters { return false }
        let maxAge = fix.isContinuous ? AppConfig.reportMaxFixAgeContinuousSeconds
                                      : AppConfig.reportMaxFixAgeSeconds
        return age <= maxAge
    }

    /// Ниже этой скорости считаем, что водитель не едет. Порог низкий (3 км/ч)
    /// намеренно: в пробке рядом с постом отметить НАДО, а вот из кресла дома —
    /// нет.
    static let minSpeedKmh: Double = 3

    /// Можно ли отправлять.
    ///
    /// `isTripActive` пропускает вперёд скорость: в активной поездке водитель
    /// стоит в пробке ровно там, где стоит и патруль, — глушить его отметку
    /// значило бы терять самые ценные точки.
    /// `fix` — качество своей точки; нужно только слепому тапу: точку,
    /// показанную пальцем на карте, выбрали, а не взяли из GPS.
    static func check(kind: ReportKind,
                      coordinate: CLLocationCoordinate2D?,
                      speedKmh: Double,
                      isTripActive: Bool,
                      placement: Placement = .blind,
                      fix: Fix?,
                      lastSent: Sent?,
                      now: Date) -> Refusal? {
        guard let coordinate, CLLocationCoordinate2DIsValid(coordinate),
              !(coordinate.latitude == 0 && coordinate.longitude == 0)
        else { return .noPosition }
        if placement == .blind, !(fix.map(isTrusted) ?? false) { return .noPosition }

        if placement == .blind, !isTripActive, speedKmh < minSpeedKmh { return .notDriving }

        if let lastSent, lastSent.kind == kind,
           now.timeIntervalSince(lastSent.at) < duplicateWindowSeconds,
           GeoMath.fastDistance(coordinate.latitude, coordinate.longitude,
                                lastSent.latitude, lastSent.longitude)
               < duplicateRadiusMeters {
            return .duplicate
        }
        return nil
    }

    /// Последняя своя отметка после ответа сервера. Досылка из очереди её не
    /// подменяет: связь вернулась, ушла старая точка A, водитель тут же
    /// отметил B — и если ответ по A приходил позже, «Перекрыто», «Отменить»
    /// и защита от дублей работали с A (ловец багов, 39).
    static func lastAfterDelivery(current: Sent?, delivered: Sent, isLive: Bool) -> Sent? {
        isLive ? delivered : current
    }
}
