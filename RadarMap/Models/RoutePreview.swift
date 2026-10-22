//
//  RoutePreview.swift
//  RadarMap
//
//  Выбор маршрута на карте (27.D, владелец: «постройку маршрута тоже»
//  приятнее). Три вопроса, у каждого — чистая функция с тестом
//  (RoutePreviewTests), потому что все три раньше решались «на глаз»:
//
//    * какой вариант под пальцем — касание линии на карте выбирает вариант,
//      как у Яндекса; на общем отрезке двух вариантов выбранный не меняется;
//    * какие поля у кадра «весь маршрут» — по НАСТОЯЩИМ панелям экрана
//      (MapFrameState), а не постоянным 150/240 pt: на SE и с тремя
//      вариантами карточка выше, и линия уходила под неё;
//    * где на линии варианта подпись «24 мин» — там, где он дальше всего от
//      остальных: на общем отрезке подписи легли бы друг на друга.
//
//  Кадр считаем сами, а не `setVisibleCoordinateBounds` движка: тот вписывал
//  только при текущих наклоне и повороте, и перед ним карту приходилось
//  рывком класть плашмя; своя камера едет туда плавно одним ходом.
//

import CoreGraphics
import CoreLocation
import MapKit

nonisolated enum RoutePreview {

    // MARK: - Касание линии

    /// Линия варианта в точках экрана.
    struct Line: Equatable, Sendable {
        let id: Int
        let points: [CGPoint]
    }

    /// Расстояние от точки до ломаной, точки экрана. Пустая — бесконечность.
    static func distance(from point: CGPoint, to polyline: [CGPoint]) -> CGFloat {
        guard let first = polyline.first else { return .infinity }
        guard polyline.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
        var best = CGFloat.infinity
        for (a, b) in zip(polyline, polyline.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length > 0 ? max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length)) : 0
            best = min(best, hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy)))
        }
        return best
    }

    /// Какой вариант выбран касанием. nil — мимо всех линий дальше `threshold`.
    ///
    /// Варианты часто идут вместе первые и последние километры: касание общего
    /// отрезка — это касание выбранного, и выбор не прыгает. Поэтому выбранный
    /// побеждает, если он не дальше ближайшего чужого больше чем на `margin`.
    static func variant(at tap: CGPoint, lines: [Line], selected: Int?,
                        threshold: CGFloat = AppConfig.routeVariantTapPoints,
                        margin: CGFloat = AppConfig.routeVariantTapMarginPoints) -> Int? {
        let distances = lines.map { (id: $0.id, d: distance(from: tap, to: $0.points)) }
            .filter { $0.d <= threshold }
        guard let nearest = distances.min(by: { $0.d < $1.d }) else { return nil }
        if let selected, let own = distances.first(where: { $0.id == selected }),
           own.d <= nearest.d + margin {
            return selected
        }
        return nearest.id
    }

    // MARK: - Поля кадра «весь маршрут»

    /// Поля вписывания, точки вида.
    struct Padding: Equatable, Sendable {
        var top: Double
        var left: Double
        var bottom: Double
        var right: Double
    }

    /// Поля по измеренным панелям.
    ///
    /// `panelTop` — нижняя кромка верхней стопки, `panelBottom` — верхняя
    /// кромка нижней (обе от верха вида; 0 — «ещё не мерили»: тогда снизу
    /// запасная доля `fallbackBottomShare`, а не ноль — карточка выбора уже
    /// на экране, просто её ещё не измерили). Сбоку — колонка кнопок.
    ///
    /// Если на линию остаётся меньше `minFree` по высоте (SE, три варианта,
    /// объявление сверху), сначала ужимаются отступы до панелей, потом —
    /// поровну сами панели: линия частью под карточкой лучше, чем линия в
    /// полоску толщиной в палец.
    static func padding(width: Double, height: Double, panelTop: Double, panelBottom: Double,
                        leading: Double = AppConfig.routeOverviewSidePoints,
                        trailing: Double = AppConfig.routeOverviewColumnPoints,
                        margin: Double = AppConfig.routeOverviewMarginPoints,
                        minFree: Double = AppConfig.routeOverviewMinFreePoints) -> Padding {
        guard width > 0, height > 0 else { return Padding(top: 0, left: 0, bottom: 0, right: 0) }
        var top = max(0, min(panelTop, height))
        let bottomEdge = panelBottom > 0 ? min(panelBottom, height)
            : height * (1 - AppConfig.routeOverviewFallbackBottomShare)
        var bottom = max(0, height - bottomEdge)
        var gap = margin
        let need = min(minFree, height * 0.8)
        var free = height - top - bottom - 2 * gap
        if free < need {
            // Отступы — до минимального зазора.
            let minGap = AppConfig.routeOverviewMinMarginPoints
            gap = max(minGap, gap - (need - free) / 2)
            free = height - top - bottom - 2 * gap
        }
        if free < need, top + bottom > 0 {
            // Панели — пропорционально своей высоте.
            let cut = min(top + bottom, need - free)
            let share = top / (top + bottom)
            top -= cut * share
            bottom -= cut * (1 - share)
        }
        var left = leading + margin / 2, right = trailing + margin / 2
        let minWidth = min(AppConfig.routeOverviewMinFreePoints, width * 0.6)
        if width - left - right < minWidth {
            let scale = max(0, width - minWidth) / max(1, left + right)
            left *= scale
            right *= scale
        }
        return Padding(top: top + gap, left: left, bottom: bottom + gap, right: right)
    }

    // MARK: - Кадр

    /// Камера кадра: центр вида и масштаб движка (MapLibre, тайл 512 pt).
    struct Fit: Equatable, Sendable {
        let center: CLLocationCoordinate2D
        let zoom: Double

        static func == (a: Fit, b: Fit) -> Bool {
            a.center.latitude == b.center.latitude && a.center.longitude == b.center.longitude
                && a.zoom == b.zoom
        }
    }

    /// Вписать прямоугольник карты в вид размера `width × height` с полями
    /// `padding`, север вверху, без наклона. Прямоугольник ложится в центр
    /// СВОБОДНОЙ части вида — между панелями, а не в центр экрана.
    static func fit(_ rect: MKMapRect, width: Double, height: Double, padding: Padding,
                    minZoom: Double = AppConfig.routeOverviewMinZoom,
                    maxZoom: Double = AppConfig.routeOverviewMaxZoom) -> Fit? {
        guard !rect.isNull, width > 0, height > 0 else { return nil }
        let world = MKMapSize.world.width
        let freeWidth = max(1, width - padding.left - padding.right)
        let freeHeight = max(1, height - padding.top - padding.bottom)
        // Линия строго с севера на юг (или точка) — ширина ноль: масштаб
        // задаёт другая сторона, а без обеих — потолок.
        let byWidth = rect.size.width > 0 ? log2(freeWidth * world / (rect.size.width * 512)) : maxZoom
        let byHeight = rect.size.height > 0 ? log2(freeHeight * world / (rect.size.height * 512)) : maxZoom
        let zoom = min(maxZoom, max(minZoom, min(byWidth, byHeight)))
        // Точек экрана на единицу MKMapPoint при этом масштабе.
        let scale = 512 * pow(2, zoom) / world
        let dx = (padding.left - padding.right) / 2
        let dy = (padding.top - padding.bottom) / 2
        let centre = MKMapPoint(x: rect.midX - dx / scale, y: rect.midY - dy / scale)
        return Fit(center: centre.coordinate, zoom: zoom)
    }

    /// Где в виде окажется точка карты при кадре `fit` (север вверху, без
    /// наклона) — проверка кадра в тестах и место подписи.
    static func screenPoint(_ point: MKMapPoint, fit: Fit, width: Double, height: Double) -> CGPoint {
        let scale = 512 * pow(2, fit.zoom) / MKMapSize.world.width
        let centre = MKMapPoint(fit.center)
        return CGPoint(x: width / 2 + (point.x - centre.x) * scale,
                       y: height / 2 + (point.y - centre.y) * scale)
    }

    // MARK: - Подпись варианта на линии

    /// Точка подписи «24 мин» на линии варианта `index`: та, что дальше всего
    /// от остальных вариантов, в средней части линии (у старта и цели
    /// варианты сходятся, и подписи легли бы стопкой). Один вариант — середина.
    static func labelPoint(of index: Int, lines: [[MKMapPoint]]) -> MKMapPoint? {
        guard lines.indices.contains(index) else { return nil }
        let own = lines[index]
        guard own.count >= 2 else { return own.first }
        let samples = sampled(own, from: AppConfig.routeVariantLabelSpan.lowerBound,
                              to: AppConfig.routeVariantLabelSpan.upperBound,
                              count: AppConfig.routeVariantLabelSamples)
        let others = lines.indices.filter { $0 != index }
            .map { thinned(lines[$0], limit: AppConfig.routeVariantLabelOtherPoints) }
            .filter { !$0.isEmpty }
        guard !others.isEmpty else { return sampled(own, from: 0.5, to: 0.5, count: 1).first }
        var best = samples[samples.count / 2], bestGap = -1.0
        for sample in samples {
            let gap = others.map { mapDistance(from: sample, to: $0) }.min() ?? 0
            if gap > bestGap { best = sample; bestGap = gap }
        }
        return best
    }

    /// Точки вдоль ломаной на долях длины [from, to], равномерно по длине.
    static func sampled(_ line: [MKMapPoint], from: Double, to: Double, count: Int) -> [MKMapPoint] {
        guard line.count >= 2, count > 0 else { return line }
        var cumulative = [0.0]
        for (a, b) in zip(line, line.dropFirst()) { cumulative.append(cumulative.last! + a.distance(to: b)) }
        let total = cumulative.last!
        guard total > 0 else { return [line[0]] }
        var out: [MKMapPoint] = []
        var segment = 0
        for k in 0..<count {
            let share = count == 1 ? (from + to) / 2 : from + (to - from) * Double(k) / Double(count - 1)
            let along = total * share
            while segment < line.count - 2, cumulative[segment + 1] < along { segment += 1 }
            let span = cumulative[segment + 1] - cumulative[segment]
            let t = span > 0 ? (along - cumulative[segment]) / span : 0
            let a = line[segment], b = line[segment + 1]
            out.append(MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return out
    }

    /// Не больше `limit` точек, концы на месте: расстояние до чужой линии —
    /// для подписи, а не для оповещения, метр точности ему не нужен.
    static func thinned(_ line: [MKMapPoint], limit: Int) -> [MKMapPoint] {
        guard line.count > limit, limit >= 2 else { return line }
        let stride = Double(line.count - 1) / Double(limit - 1)
        return (0..<limit).map { line[min(line.count - 1, Int((Double($0) * stride).rounded()))] }
    }

    /// Расстояние от точки до ломаной в единицах MKMapPoint.
    static func mapDistance(from point: MKMapPoint, to line: [MKMapPoint]) -> Double {
        let screen = line.map { CGPoint(x: $0.x, y: $0.y) }
        return Double(distance(from: CGPoint(x: point.x, y: point.y), to: screen))
    }
    // MARK: - Цвет времени с пробками

    /// Цвет времени варианта — один на телефон и машину. До 27.D телефон
    /// красил по 3/12 мин, а CarPlay — по 2/10: одна и та же задержка в
    /// 11 минут была янтарной в карточке и красной на экране машины.
    enum TrafficTone: Equatable, Sendable {
        /// Данных о пробках нет — не «зелёный»: зелёный утверждал бы «пробок нет».
        case unknown
        case free, slow, heavy
    }

    static func trafficTone(delay: TimeInterval?) -> TrafficTone {
        guard let delay else { return .unknown }
        if delay >= AppConfig.routeTrafficHeavySeconds { return .heavy }
        if delay >= AppConfig.routeTrafficNoticeSeconds { return .slow }
        return .free
    }
}
