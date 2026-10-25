//
//  ManeuverCallout.swift
//  RadarMap
//
//  Выноска манёвра НА КАРТЕ (29.G, владелец 25.10: «как у Яндекса, но
//  круче»): синий «пузырь» с хвостиком у точки манёвра — ряд полос с
//  подсвеченными нужными и расстояние до поворота. Карточка сверху говорит
//  «что», выноска — «где»: глаз видит перекрёсток и тут же, на нём, свой ряд.
//
//  Решения — здесь, чистыми функциями (ManeuverCalloutTests):
//
//  • ЧТО показать (`content`) — раз на манёвр. Полосы — только по данным
//    (OSRM `lanes` или слой полос): ≤ 8, хотя бы одна наша и хотя бы одна НЕ
//    наша — если годятся все, выбирать нечего, и ряд стрелок был бы шумом.
//    Прибытие, кольцо и «прямо» — без выноски: там нет поворота, у которого
//    её ставить. Нет полос — остаётся только расстояние со стрелкой манёвра.
//  • КОГДА (`Gate`): ряд полос — в окне подъезда (то же, что у LaneFocus и
//    DriveCamera: скорость × 15 с, 150–450 м) и, раз показанный, держится до
//    самого манёвра (торможение сужает окно — ряд не должен мигать);
//    расстояние — на ближайших `maneuverCalloutMarkMeters`.
//  • ГДЕ (`place`): над точкой манёвра или под ней, со сдвигом вбок, внутри
//    свободной части экрана (под карточкой манёвра, над нижней панелью,
//    левее колонки кнопок) и мимо значка «я», камер на пути и зоны замера.
//    Не нашлось места — не показываем: перекрыть камеру хуже, чем не
//    показать выноску (ряд есть в карточке). Прежнее место держится, пока
//    оно годно, — выноска не прыгает со стороны на сторону на каждом кадре.
//
//  Только картинка: ни голос, ни оповещения отсюда не читают.
//

import CoreGraphics
import CoreLocation
import Foundation

nonisolated enum ManeuverCallout {

    // MARK: - Что

    struct Content: Equatable, Sendable {
        /// Манёвр, к которому выноска (метры от старта маршрута).
        let along: Double
        let kind: ManeuverKind?
        /// SF-символ манёвра — для выноски без полос.
        let icon: String
        /// Ряд полос; пусто — полос нет или выбирать из них нечего.
        let lanes: [LaneHint]
    }

    /// Ряд полос, который стоит показывать: есть из чего выбрать.
    static func decisiveLanes(_ lanes: [LaneHint]) -> [LaneHint] {
        guard !lanes.isEmpty, lanes.count <= AppConfig.maneuverCalloutMaxLanes,
              lanes.contains(where: \.isValid), lanes.contains(where: { !$0.isValid }) else { return [] }
        return lanes
    }

    /// Выноска для манёвра; nil — у этого манёвра её не бывает.
    static func content(step: RouteStep?) -> Content? {
        guard let step, let kind = step.kind else { return nil }
        switch kind {
        case .arrive, .roundabout, .straight: return nil
        default: break
        }
        return Content(along: step.distanceAlong, kind: kind, icon: step.icon,
                       lanes: decisiveLanes(step.lanes))
    }

    // MARK: - Когда

    /// Что показать сейчас.
    struct Shown: Equatable, Sendable {
        var lanes: Bool
        /// Метры, округлённые для подписи; nil — расстояние не пишем.
        var meters: Int?
        var isEmpty: Bool { !lanes && meters == nil }
    }

    /// Подпись расстояния: до 100 м — шагом 5, дальше — 10; дальше
    /// `maneuverCalloutMarkMeters` и у самой точки — не пишем.
    static func markMeters(_ distance: Double) -> Int? {
        guard distance.isFinite, distance >= AppConfig.maneuverCalloutGoneMeters,
              distance <= AppConfig.maneuverCalloutMarkMeters else { return nil }
        let step: Double = distance < 100 ? 5 : 10
        return Int((distance / step).rounded() * step)
    }

    /// Гистерезис показа: ряд полос, раз появившись для манёвра, держится до
    /// него, даже если окно сузилось торможением.
    struct Gate: Equatable, Sendable {
        private(set) var lanesShownFor: Double?

        mutating func update(content: Content?, distance: Double, speedKmh: Double) -> Shown {
            guard let content, distance.isFinite, distance >= AppConfig.maneuverCalloutGoneMeters else {
                lanesShownFor = nil
                return Shown(lanes: false, meters: nil)
            }
            if lanesShownFor != content.along { lanesShownFor = nil }
            if !content.lanes.isEmpty, distance <= LaneFocus.window(speedKmh: speedKmh) {
                lanesShownFor = content.along
            }
            return Shown(lanes: lanesShownFor == content.along, meters: markMeters(distance))
        }
    }

    // MARK: - Где

    /// Сторона выноски относительно точки манёвра: над ней, сбоку (хвостик
    /// горизонтально), снизу-сбоку (хвостик наискось из верхнего угла) или
    /// под ней.
    enum Side: Equatable, Sendable { case above, left, right, belowLeft, belowRight, below }

    /// Место выноски: тело и где у него хвостик.
    struct Placement: Equatable, Sendable {
        let side: Side
        /// Сдвиг тела вбок от точки (над/под), доля «полуширина минус
        /// скругление и хвостик»: −1…1. Сбоку — 0.
        let shift: Double
        let frame: CGRect
        /// Кончик хвостика — точка манёвра на экране.
        let tip: CGPoint
    }

    /// Порядок проб над и под точкой: прямо, затем со сдвигом в стороны.
    static let shifts: [Double] = [0, -0.8, 0.8]

    /// Порядок сторон. Над точкой — лучше всего: там дорога ЗА поворотом,
    /// она важна меньше подъезда. Затем сбоку и снизу-сбоку — со стороны
    /// ПРОТИВ поворота (направо поворачиваем — выноска слева, выезд виден),
    /// потом с другой. Прямо под точкой — последней: там подъезд, стоп-линия
    /// и стрелки полос на асфальте (их стерегут точки `avoid` подъезда).
    static func order(turn: ManeuverKind.Side?) -> [(Side, Double)] {
        let near: [Side] = turn == .left ? [.right, .belowRight, .left, .belowLeft]
                                         : [.left, .belowLeft, .right, .belowRight]
        return shifts.map { (Side.above, $0) } + near.map { ($0, 0) } + shifts.map { (Side.below, $0) }
    }

    /// Где поставить выноску размера `size` у точки `anchor`. `clear` — где
    /// ей можно быть; `avoid` — что закрывать нельзя (значок «я», камеры,
    /// зона замера, подъезд к повороту). `previous` — прошлое место: годно —
    /// остаётся (выноска не прыгает со стороны на сторону на каждом кадре).
    static func place(anchor: CGPoint, size: CGSize, clear: CGRect, avoid: [CGRect],
                      previous: Placement?, turn: ManeuverKind.Side? = nil) -> Placement? {
        let tail = AppConfig.maneuverCalloutTailPoints
        guard size.width > 0, size.height > 0, clear.width > 0, clear.height > 0,
              anchor.x.isFinite, anchor.y.isFinite,
              // Точка может стоять у самой кромки панели (кадр подъезда
              // держит поворот наверху): хвостик дотянется на свою длину.
              clear.insetBy(dx: -1, dy: -tail).contains(anchor) else { return nil }
        if let previous, let kept = frame(previous.side, previous.shift, anchor: anchor, size: size,
                                          clear: clear, avoid: avoid) { return kept }
        for (side, shift) in order(turn: turn) {
            if let found = frame(side, shift, anchor: anchor, size: size, clear: clear, avoid: avoid) { return found }
        }
        return nil
    }

    /// Одна проба: тело и хвостик для стороны; nil — не влезает или
    /// закрывает то, что нельзя.
    static func frame(_ side: Side, _ shift: Double, anchor: CGPoint, size: CGSize,
                      clear: CGRect, avoid: [CGRect]) -> Placement? {
        let tail = AppConfig.maneuverCalloutTailPoints
        let reach = max(0, size.width / 2 - AppConfig.maneuverCalloutCornerPoints - tail)
        let frame: CGRect
        let tailRect: CGRect
        switch side {
        case .above, .below:
            let x = anchor.x - size.width / 2 - CGFloat(shift) * reach
            let y = side == .above ? anchor.y - tail - size.height : anchor.y + tail
            frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            tailRect = side == .above
                ? CGRect(x: anchor.x - tail, y: frame.maxY, width: tail * 2, height: max(0, anchor.y - frame.maxY))
                : CGRect(x: anchor.x - tail, y: anchor.y, width: tail * 2, height: max(0, frame.minY - anchor.y))
        case .left, .right:
            let x = side == .left ? anchor.x - tail - size.width : anchor.x + tail
            frame = CGRect(x: x, y: anchor.y - size.height / 2, width: size.width, height: size.height)
            tailRect = side == .left
                ? CGRect(x: frame.maxX, y: anchor.y - tail, width: max(0, anchor.x - frame.maxX), height: tail * 2)
                : CGRect(x: anchor.x, y: anchor.y - tail, width: max(0, frame.minX - anchor.x), height: tail * 2)
        case .belowLeft, .belowRight:
            // Верхний угол тела — у точки, наискось вниз-вбок: тело не
            // ложится на линию подъезда, идущую из точки вниз.
            let gap = AppConfig.maneuverCalloutDiagonalGapPoints
            let x = side == .belowLeft ? anchor.x - gap - size.width : anchor.x + gap
            frame = CGRect(x: x, y: anchor.y + tail, width: size.width, height: size.height)
            tailRect = CGRect(x: min(anchor.x, side == .belowLeft ? frame.maxX : frame.minX), y: anchor.y,
                              width: gap, height: tail)
        }
        guard clear.contains(frame) else { return nil }
        // Ни тело, ни хвостик не ложатся на значок «я», камеру, подъезд.
        guard !avoid.contains(where: { $0.intersects(frame) || $0.intersects(tailRect) }) else { return nil }
        return Placement(side: side, shift: shift, frame: frame, tip: anchor)
    }

    /// Экран для выноски: где ей можно быть и что всегда закрыто (круг
    /// скорости в углу над нижней панелью). Меняется со сменой панелей.
    struct Frame: Equatable, Sendable {
        var clear: CGRect
        var blocked: [CGRect] = []
    }

    /// Свободная часть экрана: под верхними панелями, над нижними, между
    /// краем и колонкой кнопок. Доли высоты — как у MapViewport.Insets.
    static func clearRect(width: Double, height: Double, topShare: Double, bottomShare: Double,
                          left: Double, right: Double, margin: Double) -> CGRect {
        let top = height * topShare + margin
        let bottom = height * (1 - bottomShare) - margin
        let minX = left + margin, maxX = width - right - margin
        guard bottom > top, maxX > minX else { return .zero }
        return CGRect(x: minX, y: top, width: maxX - minX, height: bottom - top)
    }

    /// Квадрат вокруг экранной точки (значок, камера).
    static func box(_ point: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }

    /// Рамка вокруг нескольких точек (зона замера по её контуру) с полем.
    static func box(_ points: [CGPoint], pad: CGFloat) -> CGRect? {
        let finite = points.filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = finite.first else { return nil }
        var rect = CGRect(origin: first, size: .zero)
        for point in finite.dropFirst() { rect = rect.union(CGRect(origin: point, size: .zero)) }
        return rect.insetBy(dx: -pad, dy: -pad)
    }

    // MARK: - Точка манёвра на линии

    /// Точка линии маршрута в `along` метрах от начала (длины — те же, что у
    /// прогресса маршрута: `cumulative`); nil — линии нет.
    static func point(along: Double, route: [CLLocationCoordinate2D],
                      cumulative: [Double]) -> CLLocationCoordinate2D? {
        guard route.count >= 2, cumulative.count == route.count, along.isFinite else { return nil }
        let target = min(max(0, along), cumulative[cumulative.count - 1])
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= target { lo = mid } else { hi = mid }
        }
        let span = cumulative[hi] - cumulative[lo]
        let t = span > 0 ? (target - cumulative[lo]) / span : 0
        let a = route[lo], b = route[hi]
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                      longitude: a.longitude + (b.longitude - a.longitude) * t)
    }
}
