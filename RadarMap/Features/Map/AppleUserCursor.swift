//
//  AppleUserCursor.swift
//  RadarMap
//
//  Выбранный значок «я» на карте Apple — вместо системной синей точки.
//
//  Только для значков, выбранных водителем. Стрелка на карте Apple остаётся
//  системной точкой: у неё есть то, чего нет у нашей картинки, — круг
//  точности и конус компаса на стоянке, — и человек, ничего не выбиравший,
//  не должен заметить никакой перемены.
//
//  Отдельная вью — изолятор пер-тиковых чтений (ARCHITECTURE.md, правило 13):
//  курс и поворот карты меняются каждый фикс, и прочитанные в body карты они
//  пересобирали бы весь экран. Здесь их читает вью размером с машину.
//
//  Содержимое Annotation в MapKit выровнено по экрану и с картой НЕ
//  вращается — тот же закон, что у клина направления на маркере камеры
//  (MapState.mapHeading). Поэтому поворот значка — курс МИНУС поворот карты.
//

import CoreLocation
import SwiftUI

struct AppleUserCursor: View {
    let location: LocationService
    let map: MapState
    let style: CursorStyle
    /// Куда смотрит телефон (из UserAnnotation). Нужен в одном режиме — когда
    /// карту крутит компас: тогда поворот карты знает только он.
    let deviceHeading: CLLocationDirection?
    /// Угол на экране БЕЗ свёртки в 0…360: иначе переход 359° → 1° анимация
    /// проходила бы длинным путём — машина делала бы полный круг на месте.
    @State private var angle: Double = 0

    var body: some View {
        let target = Self.screenAngle(course: location.displayCourse,
                                      mapHeading: map.mapHeading,
                                      deviceHeading: deviceHeading)
        MeCursor(style: style)
            .frame(width: 30, height: 36)
            .rotationEffect(.degrees(angle))
            .onChange(of: target, initial: true) { _, new in
                // Курса нет (стоим) — значок держит последний поворот, как
                // стрелка движка: прыжок носом на север обещал бы направление,
                // которого никто не измерял.
                guard let new else { return }
                withMotion(.linear(duration: 0.35)) {
                    angle = EngineMapPresentation.heading(new, near: angle)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)   // где мы — VoiceOver говорит панель
    }

    /// Поворот значка на экране, градусы 0…360. nil — повернуть честно нельзя:
    /// курса нет или неизвестно, куда повёрнута сама карта.
    nonisolated static func screenAngle(course: CLLocationDirection,
                                        mapHeading: Double?,
                                        deviceHeading: CLLocationDirection?) -> Double? {
        guard course.isFinite, course >= 0 else { return nil }
        // Поворот карты: известный (север вверху, слежение по курсу, ручной
        // поворот) — у MapState; неизвестный (карту крутит компас) — у компаса.
        let compass = deviceHeading.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        guard let up = mapHeading ?? compass else { return nil }
        let raw = (course - up).truncatingRemainder(dividingBy: 360)
        return raw < 0 ? raw + 360 : raw
    }
}
