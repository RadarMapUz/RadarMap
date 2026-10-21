//
//  CarPlayCameraBannerLook.swift
//  RadarMap
//
//  Картинки баннера камеры в машине на iOS 27 (25.H1).
//
//  С iOS 27 у CPNavigationAlert есть две картинки (CPNavigationAlert.h):
//  `avatarImage` — в верхнем левом углу, и `alertImage` — над кнопками
//  («система вправе её скрыть, если места мало»). До 27-й баннер нёс один
//  значок типа и строку «Ограничение 60 · Камера». Теперь:
//    • аватар — значок типа камеры в цвете её маркера на карте (тот же диск,
//      что водитель видит у дороги);
//    • картинка — знак ограничения у камеры и полоса приближения, та же, что
//      на полноэкранной тревоге телефона (`ApproachAlertView.proximity`);
//      лимит неизвестен — вместо знака значок типа.
//  Картинка — битмап, и каждое её обновление — сообщение в машину с
//  растром. Поэтому полоса идёт ступенями (`carPlayBannerProximitySteps`), а
//  перерисовка — только когда сменилась ступень или знак; цифра расстояния
//  по-прежнему в заголовке и обновляется не чаще раза в секунду.
//
//  Только вид: решение «предупреждать ли» и о какой камере — у гейтов
//  оповещений (CarPlayCameraCue), голос и звук это не трогает.
//
//  Чистая логика; CarPlayCameraBannerLookTests.
//

import CoreGraphics

nonisolated enum CarPlayCameraBannerLook {

    /// Что стоит слева в картинке.
    enum Lead: Equatable, Sendable {
        /// Знак ограничения у камеры.
        case limit(Int)
        /// Лимит неизвестен — значок типа.
        case type
    }

    /// Всё, от чего зависит растр картинки. Сменилось — перерисовать.
    struct Art: Equatable, Sendable {
        let lead: Lead
        /// Ступень полосы приближения, 0…steps.
        let step: Int
        let steps: Int
    }

    /// 0…1 — насколько близко: как полоса на телефоне (ApproachAlertView).
    static func proximity(distance: Double, radius: Double) -> Double {
        max(0, min(1, 1 - distance / max(radius, 1)))
    }

    /// Ступень полосы. Вниз — отбрасыванием: полоса не обгоняет машину.
    static func step(proximity: Double, steps: Int = AppConfig.carPlayBannerProximitySteps) -> Int {
        let steps = max(1, steps)
        return min(steps, max(0, Int((proximity * Double(steps)).rounded(.down))))
    }

    static func art(limit: Int?, distance: Double, radius: Double,
                    steps: Int = AppConfig.carPlayBannerProximitySteps) -> Art {
        Art(lead: limit.map(Lead.limit) ?? .type,
            step: step(proximity: proximity(distance: distance, radius: radius), steps: steps),
            steps: max(1, steps))
    }

    /// Размер картинки: желаемый, вписанный в предел системы с сохранением
    /// пропорций. Предел известен только во время работы
    /// (`CPNavigationAlert.maximumAlertImageSize`); нулевой или битый —
    /// желаемый как есть.
    static func fit(_ preferred: CGSize, into maximum: CGSize) -> CGSize {
        guard maximum.width > 0, maximum.height > 0, preferred.width > 0, preferred.height > 0 else {
            return preferred
        }
        let scale = min(1, maximum.width / preferred.width, maximum.height / preferred.height)
        return CGSize(width: (preferred.width * scale).rounded(.down),
                      height: (preferred.height * scale).rounded(.down))
    }
}
