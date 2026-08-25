//
//  RoadSketchView.swift
//  RadarMap
//
//  Отрисовка схемы «где камера» для приборки: чертим сами, без карты и без
//  сети.
//
//  Устройство повторяет архитектуру RoadSketch: сцена «север вверху»
//  растеризуется ОДИН раз (Canvas + drawingGroup → текстура), а движение
//  между GPS-тиками изображают три transform'а — сдвиг (я еду), поворот (мой
//  курс — вверх) и зум (охват по дистанции до камеры). Их анимирует
//  SketchState, компоновщик считает на GPU: ни перерисовки, ни работы CPU
//  на кадр. Именно поэтому приборка остаётся самым дешёвым экраном
//  приложения — и при этом движется плавно, а не прыжками раз в секунду.
//
//  Порядок transform'ов значим: offset (я — в центр растра) → rotation
//  (вокруг меня) → scale (вокруг меня) → position (я — в точку «я» вида).
//  Математика продублирована в RoadSketch.screenPoint и проверена тестами.
//
//  Слои разложены по трём корзинам, и это правило, а не привычка:
//  • РАСТР — то, что живёт в метрах и меняется редко: сеть, полотно камеры,
//    лента маршрута, точки камер. Цена платится на пересборке, раз в сотни
//    метров.
//  • МИРОВОЙ слой — метры, но меняется чаще растра: пройденный кусок
//    маршрута, стрелка манёвра, кольцо тревожной камеры. Едет под теми же
//    transform'ами, то есть движется вместе с дорогами сам.
//  • ЭКРАННЫЙ слой — то, что не вращается вовсе: курсор «я», полосы, линейка.
//  Слой, попавший не в свою корзину, превращает приборку из самого дешёвого
//  экрана в самый дорогой — и заметно это будет не на стенде, а по нагреву.
//

import CoreLocation
import SwiftUI

struct RoadSketchView: View {
    let scene: RoadSketch.Scene
    let state: SketchState
    /// Цвет тревоги — тот же, что у дистанции рядом: схема и цифра не должны
    /// расходиться в оценке близости.
    var tint: Color = Theme.accent
    /// Накопленный сдвиг пальца: DragGesture отдаёт translation от начала
    /// жеста, а состоянию нужен шаг.
    @State private var dragged = CGSize.zero
    @State private var pinched: CGFloat = 1

    /// Во сколько раз толще линии. На телефоне 1: он в 30 см от глаз. Экран
    /// машины дальше вдвое, и те же полторы точки на нём уже не видны — там
    /// приходит AppConfig.carPlaySketchStrokeScale.
    var strokeScale: CGFloat = 1
    /// Рисовать ли отделку: осевую, шевроны, жилу ленты. В перегреве гаснет
    /// первой — см. PerformanceMode.sketchTrim.
    var trim: Bool = true

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let pivot = CGPoint(x: size.width / 2,
                                y: size.height * RoadSketch.meY)
            // Пунктов на метр растра: по высоте вид покрывает spanBucket метров.
            let k = size.height / scene.spanBucket
            // Сторона квадрата растра: круг видимости вокруг «я» при любом
            // повороте (до дальнего угла вида), с запасом на сжатие
            // scaleEffect (≤ 1/bucketRatio) и на дрейф до пересборки растра.
            let viewRadius = hypot(size.width / 2, size.height * RoadSketch.meY)
            let side = 2 * (viewRadius * RoadSketch.bucketRatio
                            + RoadSketch.driftMeters(forSpan: scene.spanAtBuild) * k)

            let cursor = cursorPoint(pivot: pivot, size: size)
            ZStack {
                // Земля — самым нижним слоем, а не фоном хоста: схема обязана
                // выглядеть одинаково и в полосе приборки, и во весь экран
                // машины, а хосты рисуют под ней разное.
                SketchPalette.ground
                world(side: side, k: k)
                    .position(pivot)
                vignette
                if !cursor.isAway {
                    ViewCone(scale: strokeScale)
                        .frame(width: 92 * strokeScale, height: 170 * strokeScale)
                        .position(x: cursor.point.x,
                                  y: cursor.point.y - 78 * strokeScale)
                        .allowsHitTesting(false)
                    MeCursor(scale: strokeScale)
                        .frame(width: 34 * strokeScale, height: 40 * strokeScale)
                        .position(cursor.point)
                } else {
                    // Машина ушла за край. Стрелка «я», которой не видно, хуже
                    // отсутствующей: вместо неё по краю показываем, В КАКУЮ
                    // СТОРОНУ осталась машина.
                    MeAway(scale: strokeScale, angle: cursor.angle)
                        .frame(width: 30 * strokeScale, height: 30 * strokeScale)
                        .position(cursor.point)
                }
                laneBubble
                streetLabel
                // Компас — только там, где для него есть место: в полосе
                // приборки в двести пунктов он был бы не ориентиром, а сором.
                if size.height >= 260 {
                    compass
                }
                scaleBar(height: size.height)
                recenterButton
            }
            .clipped()
            .contentShape(Rectangle())
            // Осмотр: тянем вид пальцем, щипком меняем охват. Жест живёт
            // здесь, а не в хосте: схема одна и та же на приборке и на экране
            // машины, и правило возврата у неё общее.
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        state.viewHeight = size.height
                        state.beginInspect()
                        state.pan(by: CGSize(width: value.translation.width - dragged.width,
                                             height: value.translation.height - dragged.height))
                        dragged = value.translation
                    }
                    .onEnded { _ in
                        dragged = .zero
                        state.endInspect()
                    }
                    .simultaneously(with: MagnifyGesture()
                        .onChanged { value in
                            state.viewHeight = size.height
                            state.beginInspect()
                            state.zoom(by: value.magnification / pinched)
                            pinched = value.magnification
                        }
                        .onEnded { _ in
                            pinched = 1
                            state.endInspect()
                        })
            )
            .onAppear { state.viewHeight = size.height }
        }
        .accessibilityHidden(true)   // цифру и сторону рядом VoiceOver уже читает
    }

    /// Мир: растр сцены, пройденный кусок, стрелка манёвра и кольцо тревожной
    /// камеры — под общими transform'ами. Всё это живёт в мировых координатах
    /// и движется вместе с дорогами само.
    private func world(side: CGFloat, k: CGFloat) -> some View {
        ZStack {
            SketchRaster(scene: scene, k: k, strokeScale: strokeScale, trim: trim)
                .equatable()
                .frame(width: side, height: side)
            RouteOverlay(passed: state.passedPath, maneuver: state.maneuverPath,
                         kind: state.maneuverKind, k: k, side: side,
                         strokeScale: strokeScale)
                .equatable()
                .frame(width: side, height: side)
            if let camera = scene.alertCamera {
                AlertCameraMarker(tint: tint, scale: strokeScale)
                    .position(x: side / 2 + camera.x * k,
                              y: side / 2 - camera.y * k)
            }
        }
        .frame(width: side, height: side)
        .offset(x: -state.viewOffset.width * k, y: state.viewOffset.height * k)
        .rotationEffect(.degrees(-state.courseDegrees))
        .scaleEffect(scene.spanBucket / state.spanMeters)
        // Наклон — ЧЕТВЁРТЫЙ transform на той же готовой текстуре, и в этом
        // весь его смысл. Мир уже растеризован и уже крутится компоновщиком;
        // перспектива не добавляет ни перерисовки, ни работы CPU на кадр —
        // ровно поэтому наклон, отвергнутый когда-то как «непрерывный GPU»,
        // здесь стоит почти ноль. Вокруг «я»: точка водителя остаётся на
        // месте, а дорога впереди уходит к горизонту.
        .rotation3DEffect(.degrees(tiltDegrees), axis: (x: 1, y: 0, z: 0),
                          anchor: .center, perspective: 0.62)
        .animation(.easeInOut(duration: 0.55), value: tiltDegrees)
    }

    /// Угол наклона.
    ///
    /// В перспективе расстояние по экрану НЕЛИНЕЙНО: камера в трёхстах метрах
    /// стоит не вдвое дальше по картинке, чем камера в ста пятидесяти, а
    /// заметно ближе к горизонту. Для красивой картинки это неважно, а для
    /// вопроса «далеко ли до камеры» — важнее всего остального: схема ради
    /// него и существует.
    ///
    /// Поэтому наклон уходит в ноль, как только тревожная камера попадает в
    /// охват. Пока дорога чиста — вид навигаторский; когда впереди камера —
    /// вид становится честной сверху-вниз схемой с линейным масштабом. Переход
    /// анимирован, и водитель читает его как «приготовились».
    private var tiltDegrees: Double {
        // Осмотр выпрямляет вид по той же причине, что и тревога: карту
        // осматривают ради расстояний, а в перспективе расстояние по экрану
        // нелинейно.
        scene.alertCameraID == nil && !state.isInspecting
            ? AppConfig.sketchTiltDegrees : 0
    }

    /// Виньетка: дороги растворяются у краёв, а не обрываются.
    ///
    /// Затухание по двум осям и В ДОЛЯХ размера, а не четырьмя полосками по
    /// 22–26 пунктов. Фиксированные пункты были неправы там, где важнее
    /// всего: на широком экране машины они превращались в ниточку по краю, и
    /// растворения не было вовсе.
    ///
    /// Радиальную маску пробовал — она проще, но на узкой вью приборки до
    /// боков не достаёт: расстояние до края по горизонтали там вдвое меньше,
    /// чем до угла, и стороны остаются с ножевым срезом. По осям — работает
    /// при любой пропорции.
    ///
    /// Гасим в ЧЁРНЫЙ, а не в землю. Земля — прямоугольник во всю вью, и
    /// растворять в неё значит оставить её собственный край: схема читалась
    /// карточкой с отчётливой рамкой по периметру. Чёрный — фон обоих хостов,
    /// поэтому в него уходит и полотно, и сама земля, и края нет вовсе.
    private var vignette: some View {
        let horizontal = LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .clear, location: 0.13),
                .init(color: .clear, location: 0.87),
                .init(color: .black, location: 1),
            ]), startPoint: .leading, endPoint: .trailing)
        let vertical = LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .clear, location: 0.10),
                .init(color: .clear, location: 0.90),
                .init(color: .black, location: 1),
            ]), startPoint: .top, endPoint: .bottom)
        return Color.clear
            .overlay(horizontal)
            .overlay(vertical)
            .allowsHitTesting(false)
    }

    /// Полосы на подходе к манёвру — экранным слоем сверху по центру, как у
    /// больших навигаторов: ряд не вращается вместе с картой, потому что
    /// водитель сверяет его со своим лобовым стеклом, а не с полотном схемы.
    ///
    /// Показывается ТОЛЬКО когда полосы пришли от роутера. Нет данных — нет
    /// ряда: нарисовать три полосы по догадке значит дать указание, которого
    /// никто не давал.
    @ViewBuilder
    private var laneBubble: some View {
        if !state.lanes.isEmpty {
            HStack(spacing: 3 * strokeScale) {
                ForEach(Array(state.lanes.enumerated()), id: \.offset) { _, lane in
                    Image(systemName: lane.primaryArrow(for: state.maneuverKind).symbolName)
                        .font(.rounded(15 * strokeScale, .bold))
                        .foregroundStyle(lane.isValid ? Color.white
                                                      : Color.white.opacity(0.30))
                        .frame(width: 22 * strokeScale)
                }
            }
            .padding(.horizontal, 9 * strokeScale)
            .padding(.vertical, 6 * strokeScale)
            .background(Color.black.opacity(0.80),
                        in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 6 * strokeScale)
            .allowsHitTesting(false)
        }
    }

    /// Имя улицы под курсором.
    ///
    /// Одна строка, а не подписи на всех улицах: мелкий текст с держателя не
    /// читается, а имя дороги, по которой едешь, — читается и нужно. Все
    /// навигаторы показывают ровно это и ровно так.
    ///
    /// Экранным слоем и вне наклона: подпись читают как прибор, а не как
    /// предмет, лежащий на асфальте.
    @ViewBuilder
    private var streetLabel: some View {
        if let street = state.currentStreet, !street.isEmpty {
            Text(street)
                .font(.rounded(13 * strokeScale, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10 * strokeScale)
                .padding(.vertical, 4 * strokeScale)
                .background(Color.black.opacity(0.55), in: Capsule())
                .frame(maxWidth: 220 * strokeScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 34 * strokeScale)
                .allowsHitTesting(false)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.35), value: street)
        }
    }

    /// Где на экране машина и видно ли её.
    ///
    /// Обычно — в точке «я», прибитой к 78% высоты. При осмотре вид замирает,
    /// а машина едет дальше, и курсор уезжает от неё ровно на разницу. Уехал
    /// за край — прижимаем к краю и разворачиваем указателем: «машина там».
    private func cursorPoint(pivot: CGPoint,
                             size: CGSize) -> (point: CGPoint, isAway: Bool, angle: Double) {
        let offset = RoadSketch.screenOffset(fromScene: state.cursorOffset,
                                             courseDegrees: state.courseDegrees,
                                             spanMeters: state.spanMeters,
                                             viewHeight: size.height)
        let raw = CGPoint(x: pivot.x + offset.width, y: pivot.y + offset.height)
        let inset = 26 * strokeScale
        let clamped = CGPoint(x: min(max(raw.x, inset), size.width - inset),
                              y: min(max(raw.y, inset), size.height - inset))
        let away = abs(clamped.x - raw.x) > 0.5 || abs(clamped.y - raw.y) > 0.5
        let angle = atan2(raw.y - clamped.y, raw.x - clamped.x) * 180 / .pi
        return (clamped, away, angle)
    }

    /// «К себе». Появляется, только когда вид уведён, и исчезает сам —
    /// кнопка, которую видно всегда, за рулём становится шумом.
    @ViewBuilder
    private var recenterButton: some View {
        if state.isInspecting {
            Button { state.returnToMe() } label: {
                Image(systemName: "location.fill")
                    .font(.rounded(15 * strokeScale, .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40 * strokeScale, height: 40 * strokeScale)
                    .background(Color.black.opacity(0.72), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 12 * strokeScale)
            .padding(.bottom, 12 * strokeScale)
            .transition(.opacity.combined(with: .scale))
            .animation(.easeOut(duration: 0.25), value: state.isInspecting)
        }
    }

    /// Компас. Схема всегда повёрнута по ходу движения, то есть «вверх» на
    /// ней — это куда я еду, а не север. Пока едешь прямо, это незаметно; на
    /// развязке, где схема провернулась на сто восемьдесят, стрелка на север
    /// — единственное, что связывает картинку с реальным миром.
    ///
    /// Экранным слоем и вне наклона: компас читают как прибор, а не как
    /// предмет, лежащий на дороге.
    private var compass: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.55))
                .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
            Image(systemName: "location.north.fill")
                .font(.rounded(11 * strokeScale, .bold))
                .foregroundStyle(Theme.danger.opacity(0.9))
                .offset(y: -3 * strokeScale)
                .rotationEffect(.degrees(-state.courseDegrees))
            Text("С")
                .font(.rounded(8 * strokeScale, .heavy))
                .foregroundStyle(Theme.textTertiary)
                .offset(y: 7.5 * strokeScale)
        }
        .frame(width: 30 * strokeScale, height: 30 * strokeScale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 8 * strokeScale)
        .padding(.trailing, 10 * strokeScale)
        .allowsHitTesting(false)
    }

    /// Линейка масштаба: схема без масштаба заставляла бы угадывать, далеко
    /// ли перекрёсток. Ширина следует за охватом и анимируется вместе с ним.
    /// Кегль и толщина растут с strokeScale: линии схемы на экране машины
    /// в 1.6 раза толще, а линейка оставалась телефонной — на грани видимости.
    private func scaleBar(height: CGFloat) -> some View {
        let meters = RoadSketch.scaleBarMeters(forSpan: state.spanMeters)
        let width = CGFloat(meters) * height / CGFloat(state.spanMeters)
        return HStack(spacing: 6) {
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: width, height: 2 * strokeScale)
            Text(Formatting.distance(meters))
                .font(.rounded(11 * max(1, strokeScale * 0.9), .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .bottomLeading)
        .padding(.leading, 30)
        .padding(.bottom, 8 * strokeScale)
        .allowsHitTesting(false)
    }
}

// MARK: - Курсор «я»

/// Курсор машины: всегда строго вверх — схема повёрнута по ходу движения,
/// поэтому «вверх» и есть «куда я еду». Экранным слоем, а не в растре: мир
/// вращается, курсор — никогда.
///
/// Объём даётся тремя тонами одного цвета и посадкой на тень, а не рисованной
/// перспективой: плоский треугольник читался указателем на чертеже, а не
/// машиной на дороге. Всё статично — ни одного пересчёта на тик.
private struct MeCursor: View {
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            // Тень: курсор садится НА полотно, а не висит над ним.
            Ellipse()
                .fill(.black.opacity(0.45))
                .frame(width: 26 * scale, height: 9 * scale)
                .blur(radius: 4 * scale)
                .offset(y: 15 * scale)
            // Основание: тот же силуэт чуть ниже и темнее — даёт толщину.
            MeCursorShape()
                .fill(SketchPalette.meBase)
                .offset(y: 2.5 * scale)
            MeCursorShape()
                .fill(LinearGradient(colors: [SketchPalette.meTop,
                                              SketchPalette.meBody],
                                     startPoint: .top, endPoint: .bottom))
            // Боковое освещение: левая грань светлее, правая уходит в тень.
            // Градиентом, а не половиной фигуры под маской: жёсткая граница по
            // оси делила курсор надвое и читалась не конусом, а сложенным
            // веером — ровно та ошибка, ради которой этот слой и рисуется.
            MeCursorShape()
                .fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0.32), location: 0),
                    .init(color: .white.opacity(0.04), location: 0.45),
                    .init(color: .black.opacity(0.26), location: 1),
                ], startPoint: .leading, endPoint: .trailing))
            MeCursorShape()
                .stroke(.white.opacity(0.85), lineWidth: 1.2 * scale)
        }
        .compositingGroup()
        .shadow(color: SketchPalette.meBody.opacity(0.55), radius: 6 * scale)
    }
}

/// Конус обзора впереди курсора.
///
/// Та самая деталь, по которой навигатор узнаётся с одного взгляда: свет фар
/// на полотне. Работы не несёт никакой — это одна статичная фигура с
/// градиентом в экранном слое, — но именно она превращает курсор из указателя
/// в машину, у которой есть «вперёд».
private struct ViewCone: View {
    var scale: CGFloat = 1

    var body: some View {
        ConeShape()
            .fill(LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: SketchPalette.meTop.opacity(0.00), location: 0),
                    .init(color: SketchPalette.meTop.opacity(0.05), location: 0.6),
                    .init(color: SketchPalette.meTop.opacity(0.13), location: 1),
                ]), startPoint: .top, endPoint: .bottom))
            // Размытие вдвое сильнее ширины раствора: узкий и сильно
            // размытый конус читается светом фар, широкий и слабо размытый —
            // двумя кляксами по бокам от курсора. Разница видна только на
            // экране, и на нём же она была поймана.
            .blur(radius: 14 * scale)
    }

    private struct ConeShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                              control: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.22))
            path.closeSubpath()
            return path
        }
    }
}

/// Маркер тревожной камеры: не точка, а знак.
///
/// Точка отвечает на вопрос «где», знак — ещё и на «что». В машине это разные
/// вопросы: красный кружок среди других красных кружков читается сыпью, а
/// пиктограмма камеры в кольце — предупреждением. Пульс — единственная
/// непрерывная анимация во всей схеме, и она того стоит: движение боковым
/// зрением ловится там, где статичная фигура теряется. Стоит она одного
/// маленького слоя у компоновщика, без единого пересчёта на кадр.
private struct AlertCameraMarker: View {
    let tint: Color
    var scale: CGFloat = 1
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.55), lineWidth: 2 * scale)
                .frame(width: 30 * scale, height: 30 * scale)
                .scaleEffect(pulsing ? 1.9 : 1)
                .opacity(pulsing ? 0 : 0.9)
            Circle()
                .fill(tint.opacity(0.18))
                .frame(width: 40 * scale, height: 40 * scale)
            Circle()
                .fill(Theme.danger)
                .frame(width: 22 * scale, height: 22 * scale)
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5 * scale))
            Image(systemName: "camera.fill")
                .font(.rounded(10 * scale, .bold))
                .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.6), radius: 3 * scale)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

/// Машина ушла за край экрана: указатель на неё.
///
/// Не курсор и не стрелка направления движения — именно указатель «машина
/// там». Спутать их нельзя: курсор всегда смотрит по курсу, а этот — на
/// машину, и в осмотре это разные стороны.
private struct MeAway: View {
    var scale: CGFloat = 1
    let angle: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.72))
                .overlay(Circle().stroke(SketchPalette.meBody.opacity(0.5), lineWidth: 1))
            Image(systemName: "location.north.fill")
                .font(.rounded(13 * scale, .bold))
                .foregroundStyle(SketchPalette.meTop)
                .rotationEffect(.degrees(angle + 90))
        }
        .shadow(color: SketchPalette.meBody.opacity(0.5), radius: 4 * scale)
    }
}

/// Силуэт курсора: остриё вверху, выпуклое книзу основание — конус, увиденный
/// чуть сверху. Выпуклое, а не плоское: плоский низ читается треугольником.
private struct MeCursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        // Уже рамки и выше: развал во всю ширину при основании на трёх
        // четвертях высоты давал приземистый треугольник с широкой юбкой.
        let half = rect.width * 0.40
        let shoulder = rect.minY + rect.height * 0.88
        var path = Path()
        path.move(to: CGPoint(x: cx, y: rect.minY))
        path.addLine(to: CGPoint(x: cx + half, y: shoulder))
        path.addQuadCurve(to: CGPoint(x: cx - half, y: shoulder),
                          control: CGPoint(x: cx, y: rect.minY + rect.height * 1.06))
        path.closeSubpath()
        return path
    }
}

// MARK: - Мировой слой маршрута

/// Пройденный кусок и стрелка манёвра.
///
/// Отдельно от растра, и это не стилистика: пройденное меняется непрерывно, а
/// окно стрелки едет вместе с машиной. В растре они заставляли бы пересобирать
/// его каждые несколько метров — то есть ровно то, ради отсутствия чего вся
/// эта архитектура и написана.
///
/// Equatable: пока обе ломаные те же, SwiftUI не трогает Canvas вовсе. Обе
/// короткие (десятки точек), сравнение дешевле перерисовки на порядки.
private struct RouteOverlay: View, Equatable {
    let passed: [CGPoint]
    let maneuver: [CGPoint]
    let kind: ManeuverKind?
    let k: CGFloat
    let side: CGFloat
    var strokeScale: CGFloat = 1

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.k == rhs.k && lhs.side == rhs.side && lhs.strokeScale == rhs.strokeScale
            && lhs.kind == rhs.kind && lhs.passed == rhs.passed
            && lhs.maneuver == rhs.maneuver
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func at(_ point: CGPoint) -> CGPoint {
                CGPoint(x: center.x + point.x * k, y: center.y - point.y * k)
            }

            if passed.count >= 2 {
                context.stroke(SketchGeometry.path(passed.map(at)),
                               with: .color(SketchPalette.routePassed),
                               style: .init(lineWidth: 6 * strokeScale,
                                            lineCap: .round, lineJoin: .round))
            }

            guard maneuver.count >= 2, kind?.isDrawable != false else { return }
            let points = maneuver.map(at)
            let head = 17 * strokeScale
            let spine = SketchGeometry.trimmed(points, byLast: head)
            guard spine.count >= 2 else { return }
            let body = SketchGeometry.path(spine)
            let arrow = SketchGeometry.arrowHead(along: points, size: head)
            // Заметно толще ленты, но не втрое: манёвр обязан выделяться из
            // маршрута, а не заслонять перекрёсток, на котором совершается.
            let width = 9 * strokeScale

            // Белая кайма — как у стрелки на дорожном знаке: она отделяет
            // манёвр от любого фона, включая ленту маршрута прямо под ним.
            context.stroke(body, with: .color(SketchPalette.maneuverCasing),
                           style: .init(lineWidth: width + 3 * strokeScale,
                                        lineCap: .round, lineJoin: .round))
            context.fill(arrow.casing, with: .color(SketchPalette.maneuverCasing))
            context.stroke(body, with: .color(SketchPalette.maneuverBody),
                           style: .init(lineWidth: width,
                                        lineCap: .round, lineJoin: .round))
            context.fill(arrow.body, with: .color(SketchPalette.maneuverBody))
        }
        // БЕЗ drawingGroup, в отличие от растра, и это принципиально. Растр
        // флэтится в текстуру потому, что его список отрисовки — сотни штрихов
        // по всей окрестности. Здесь их четыре, а рамка у слоя та же, что у
        // растра (общая система координат) — то есть drawingGroup завёл бы
        // ВТОРУЮ текстуру размером с первую ради двух ломаных. На широком
        // экране машины это десятки мегабайт видеопамяти на пустое место.
        // Список из четырёх штрихов компоновщик проигрывает дешевле, чем
        // хранит такую текстуру.
    }
}

// MARK: - Общая геометрия рисования

/// Мелкая чертёжная арифметика, общая для растра и мирового слоя. Чистая и
/// вынесенная: тем же кодом строится и полотно, и стрелка манёвра.
nonisolated enum SketchGeometry {

    static func path(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }

    /// Укоротить ломаную с конца на заданную длину: тело стрелки не должно
    /// торчать сквозь её голову.
    static func trimmed(_ points: [CGPoint], byLast length: CGFloat) -> [CGPoint] {
        guard points.count >= 2, length > 0 else { return points }
        var result = points
        var left = length
        while result.count >= 2 {
            let last = result[result.count - 1]
            let previous = result[result.count - 2]
            let segment = hypot(last.x - previous.x, last.y - previous.y)
            if segment > left {
                let t = (segment - left) / segment
                result[result.count - 1] = CGPoint(
                    x: previous.x + (last.x - previous.x) * t,
                    y: previous.y + (last.y - previous.y) * t)
                return result
            }
            left -= segment
            result.removeLast()
        }
        return result
    }

    /// Голова стрелки на конце ломаной: тело и кайма одной формой разного
    /// размера — так голова обведена ровно тем же контуром, что и тело.
    static func arrowHead(along points: [CGPoint],
                          size: CGFloat) -> (body: Path, casing: Path) {
        guard let tip = points.last, points.count >= 2 else {
            return (Path(), Path())
        }
        // Направление берём по последнему НЕвырожденному отрезку: на выходе
        // из поворота последние точки могут совпасть, и нулевой вектор
        // развернул бы голову куда угодно.
        var direction = CGPoint(x: 0, y: -1)
        for index in stride(from: points.count - 2, through: 0, by: -1) {
            let dx = tip.x - points[index].x, dy = tip.y - points[index].y
            let length = hypot(dx, dy)
            if length > 0.5 {
                direction = CGPoint(x: dx / length, y: dy / length)
                break
            }
        }
        func triangle(_ scale: CGFloat) -> Path {
            let long = size * scale
            let half = size * 0.62 * scale
            let back = CGPoint(x: tip.x - direction.x * long,
                               y: tip.y - direction.y * long)
            let across = CGPoint(x: -direction.y * half, y: direction.x * half)
            var path = Path()
            path.move(to: CGPoint(x: tip.x + direction.x * (scale - 1) * size * 0.5,
                                  y: tip.y + direction.y * (scale - 1) * size * 0.5))
            path.addLine(to: CGPoint(x: back.x + across.x, y: back.y + across.y))
            path.addLine(to: CGPoint(x: back.x - across.x, y: back.y - across.y))
            path.closeSubpath()
            return path
        }
        return (triangle(1), triangle(1.32))
    }
}

// MARK: - Растр сцены

/// Растр сцены. Equatable — SwiftUI не трогает Canvas, пока сцена та же:
/// перерисовка случается на пересборке сцены, а не на каждом тике.
private struct SketchRaster: View, Equatable {
    let scene: RoadSketch.Scene
    let k: CGFloat
    /// Множитель толщин: экран машины смотрят с вдвое большего расстояния.
    var strokeScale: CGFloat = 1
    /// Отделка (осевая, шевроны, жила ленты) — гаснет в перегреве.
    var trim: Bool = true

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.k == rhs.k && lhs.strokeScale == rhs.strokeScale
            && lhs.trim == rhs.trim && lhs.scene == rhs.scene
    }

    var body: some View {
        Canvas { context, size in
            let token = Perf.begin(Perf.Name.sketchRaster)
            defer { token.end() }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func at(_ point: CGPoint) -> CGPoint {
                CGPoint(x: center.x + point.x * k, y: center.y - point.y * k)
            }
            func path(_ points: [CGPoint]) -> Path {
                SketchGeometry.path(points.map(at))
            }

            // Местность — ПОД всем остальным: это то, по чему идут дороги.
            // Слои уже отсортированы сценой (кварталы → зелень → вода →
            // рельсы), поэтому здесь ни одной сортировки на пересборку.
            for area in scene.areas {
                let shape = path(area.points)
                if area.isClosed {
                    var closed = shape
                    closed.closeSubpath()
                    context.fill(closed, with: .color(areaFill(area.kind)))
                    if area.kind == .water {
                        // Кромка воды: без неё пруд на тёмном фоне читается
                        // дырой, а не поверхностью.
                        context.stroke(closed, with: .color(SketchPalette.waterEdge),
                                       style: .init(lineWidth: 1.2 * strokeScale,
                                                    lineJoin: .round))
                    }
                } else {
                    context.stroke(shape, with: .color(areaFill(area.kind)),
                                   style: .init(lineWidth: areaWidth(area.kind),
                                                lineCap: .round, lineJoin: .round,
                                                dash: area.kind == .rail
                                                    ? [9 * strokeScale, 6 * strokeScale] : []))
                }
            }

            // Окрестная сеть — следующий слой. Рисуем строго по возрастанию
            // уровня: сначала всё, что по земле, потом эстакады. Только так
            // камера НА мосту отличима от камеры на дороге ПОД ним — а это
            // разные камеры и разное решение водителя.
            //
            // Внутри уровня — проходами, а не по линии: сперва ВСЕ подложки
            // мостов, потом ВСЕ каймы, потом ВСЕ полотна, потом ВСЯ разметка.
            // Иначе кайма одной дороги ложилась бы поверх полотна соседней, и
            // каждый перекрёсток рассекался бы швами.
            let byLevel = Dictionary(grouping: scene.network.filter { $0.points.count >= 2 },
                                     by: \.level)
            for level in byLevel.keys.sorted() {
                let lines = byLevel[level]!
                // Мост отбивается тёмной «подложкой» шире самой линии: она
                // разрывает то, что проходит под ним, и пересечение читается
                // как развязка, а не как перекрёсток.
                if level > 0 {
                    for line in lines {
                        context.stroke(path(line.points), with: .color(.black),
                                       style: .init(lineWidth: width(for: line) + 9 * strokeScale,
                                                    lineCap: .butt, lineJoin: .round))
                    }
                }
                // Кайма ТЕМНЕЕ земли: полотно читается лежащим на ней, а две
                // параллельные улицы в пятнадцати метрах не сливаются в одну
                // широкую. Тоннелям каймы нет — они и так пунктиром «под
                // землёй».
                for line in lines where level >= 0 {
                    var shape = path(line.points)
                    if line.isRing { shape.closeSubpath() }
                    context.stroke(shape,
                                   with: .color(SketchPalette.casing),
                                   style: .init(lineWidth: width(for: line) + 3.5 * strokeScale,
                                                lineCap: .butt, lineJoin: .round))
                }
                for line in lines {
                    // Кольцо замыкается: разомкнутая развязка на схеме
                    // читается тупиком, а не кругом.
                    var shape = path(line.points)
                    if line.isRing { shape.closeSubpath() }
                    context.stroke(shape,
                                   with: .color(fill(for: line)),
                                   style: .init(lineWidth: width(for: line),
                                                lineCap: .butt, lineJoin: .round,
                                                dash: level < 0 ? [10, 8] : []))
                }
                // Заглушки узлов.
                //
                // Ways режутся на перекрёстках, и каждый кусок кончается своим
                // срезанным концом. Пока концы сходились в одной точке, стык
                // закрывала сама пересекающая дорога — но она закрывает его
                // только там, где ПРОХОДИТ. Стоит улице упереться в край
                // раздельной проезжей части или в дорогу тоньше себя, и на
                // стыке остаётся тёмный шов: на экране улица выглядит
                // разорванной ровно на перекрёстке.
                //
                // Классическое лекарство карт — заглушка: в узле, где сходятся
                // два и больше концов, кладём диск самой широкой из
                // встретившихся там дорог. Швов не остаётся ни при какой
                // геометрии, а стоит это десяток заливок на пересборку.
                var nodes: [Int64: (point: CGPoint, ends: Int,
                                    width: CGFloat, color: Color)] = [:]
                for line in lines {
                    guard let first = line.points.first,
                          let last = line.points.last else { continue }
                    let lineWidth = width(for: line)
                    let lineColor = fill(for: line)
                    for point in [first, last] {
                        let key = Int64((point.x).rounded()) &* 1_000_003
                            &+ Int64((point.y).rounded())
                        if var existing = nodes[key] {
                            existing.ends += 1
                            if lineWidth > existing.width {
                                existing.width = lineWidth
                                existing.color = lineColor
                            }
                            nodes[key] = existing
                        } else {
                            nodes[key] = (point, 1, lineWidth, lineColor)
                        }
                    }
                }
                for node in nodes.values where node.ends >= 2 {
                    let centre = at(node.point)
                    let radius = node.width / 2
                    context.fill(Path(ellipseIn: CGRect(x: centre.x - radius,
                                                        y: centre.y - radius,
                                                        width: radius * 2,
                                                        height: radius * 2)),
                                 with: .color(node.color))
                }

                // Осевая — только на крупных: на дворовом проезде её нет и в
                // жизни, а нарисованная была бы выдуманной деталью.
                for line in lines where trim && level >= 0 && hasCenterline(line) {
                    context.stroke(path(line.points),
                                   with: .color(SketchPalette.centerline),
                                   style: .init(lineWidth: 1.2 * strokeScale,
                                                lineCap: .butt,
                                                dash: [7 * strokeScale, 9 * strokeScale]))
                }
                // Стрелки односторонних — редкие шевроны по ходу точек
                // (сервер уже развернул oneway=-1 по движению).
                for line in lines where trim && line.isOneWay && line.isDetailed
                    && level >= 0 {
                    chevrons(context: &context, along: line.points.map(at))
                }
            }

            // Трек — самый бледный слой: он объясняет, откуда я приехал, и не
            // должен спорить с тем, что впереди.
            if scene.track.count >= 2 {
                context.stroke(path(scene.track),
                               with: .color(SketchPalette.track),
                               style: .init(lineWidth: 5 * strokeScale, lineCap: .round,
                                            lineJoin: .round))
            }

            // Дорога тревожной камеры. Пунктиром — если она предположена по
            // оси, а не измерена снапом: обещать точность, которой нет, нельзя.
            if scene.road.count >= 2 {
                let measured = scene.roadIsMeasured
                // Шириной с проспект, а не шире всего на экране: полоса в
                // двадцать два пункта поверх дороги в двенадцать читалась
                // отдельным предметом, начинающимся из ниоткуда, — а это ТА ЖЕ
                // дорога, только подсвеченная. Полупрозрачно по той же
                // причине: сеть под ней должна просвечивать.
                //
                // Концы срезаны, а не скруглены: измеренный кусок проезжей
                // части кончается там, где кончились данные, и круглая
                // «таблетка» посреди квартала читалась концом ДОРОГИ. Срез
                // читается обрывом наших сведений — он и есть.
                context.stroke(path(scene.road), with: .color(SketchPalette.casing),
                               style: .init(lineWidth: 20 * strokeScale * zoomWidth,
                                            lineCap: .butt,
                                            lineJoin: .round,
                                            dash: measured ? [] : [14, 10]))
                context.stroke(path(scene.road),
                               with: .color((measured ? SketchPalette.cameraRoad
                                                      : SketchPalette.cameraRoadAssumed)
                                   .opacity(0.85)),
                               style: .init(lineWidth: 16 * strokeScale * zoomWidth,
                                            lineCap: .butt,
                                            lineJoin: .round,
                                            dash: measured ? [] : [14, 10]))
                if measured, trim {
                    context.stroke(path(scene.road),
                                   with: .color(SketchPalette.centerline),
                                   style: .init(lineWidth: 1.5 * strokeScale, lineCap: .butt,
                                                dash: [10, 12]))
                }
            }

            // Маршрут — лентой в три слоя, а не линией: тёмная кайма отделяет
            // его от полотна, цветное тело — «куда я еду», светлая жила внутри
            // даёт объём. Те же три слоя, что у карты машины: там эти толщины
            // уже подобраны и проверены с водительского места.
            if scene.route.count >= 2 {
                let line = path(scene.route)
                // УЖЕ полотна, а не шире: лента в 15 пунктов накрывала
                // проспект в 12 целиком, и дорога, по которой едешь,
                // пропадала с экрана вместе со своими краями и осевой.
                // Маршрут показывает путь ПО дороге, а не вместо неё.
                context.stroke(line, with: .color(SketchPalette.routeCasing),
                               style: .init(lineWidth: 9 * strokeScale,
                                            lineCap: .round, lineJoin: .round))
                context.stroke(line, with: .color(SketchPalette.routeBody),
                               style: .init(lineWidth: 6 * strokeScale,
                                            lineCap: .round, lineJoin: .round))
                if trim {
                    context.stroke(line, with: .color(SketchPalette.routeCore),
                                   style: .init(lineWidth: 1.8 * strokeScale,
                                                lineCap: .round, lineJoin: .round))
                }
            }

            // ВСЕ камеры охвата — точками на своих местах: на ферганском
            // чорраха их четыре, и одна точка прятала три остальные. Но
            // одинаковыми они быть не должны: десяток равных точек по краям
            // читается как сыпь, а не как карта (проверено реальной поездкой).
            // Тревожная — полная, с кольцом от вью; остальные — мельче и
            // тише: контекст, а не предупреждение.
            for dot in scene.cameras {
                let point = at(dot.point)
                let isAlert = dot.id == scene.alertCameraID
                let r: CGFloat = (isAlert ? 6 : 4.5) * strokeScale
                let rect = CGRect(x: point.x - r, y: point.y - r,
                                  width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect),
                             with: .color(Theme.danger.opacity(isAlert ? 0.85 : 0.6)))
                context.stroke(Path(ellipseIn: rect),
                               with: .color(.black.opacity(0.6)), lineWidth: 1.5)
            }
        }
        .drawingGroup()   // одна текстура: transform'ы крутят её без перерисовки
    }

    private func areaFill(_ kind: SketchArea.Kind) -> Color {
        switch kind {
        case .water: return SketchPalette.water
        case .green: return SketchPalette.green
        case .rail:  return SketchPalette.rail
        case .block: return SketchPalette.block
        }
    }

    /// Ширина ленты местности. Река лентой шире рельсов: по ширине их и
    /// различают, когда цвет съеден солнцем через лобовое стекло.
    private func areaWidth(_ kind: SketchArea.Kind) -> CGFloat {
        switch kind {
        case .water: return 7 * strokeScale * zoomWidth
        case .rail:  return 2.5 * strokeScale
        case .green, .block: return 3 * strokeScale
        }
    }

    /// Осевую получают только дороги, у которых она есть в жизни, и только
    /// когда класс ИЗМЕРЕН. Источник без классов не размечается вовсе.
    private func hasCenterline(_ line: RoadSketch.Line) -> Bool {
        guard line.isDetailed, !line.isOneWay else { return false }
        switch line.kind {
        case .motorway, .trunk, .primary, .secondary: return true
        default: return false
        }
    }

    /// Ширина линии по классу дороги: магистраль толстая, двор тонкий — схема
    /// читается как местность, а не как паутина одинаковых линий.
    ///
    /// Источник, который класса НЕ ЗНАЕТ (индекс лимитов), получает одну
    /// среднюю ширину на всё. Рисовать разную толщину по догадке значило бы
    /// выдавать предположение за измеренное — здесь это так же недопустимо,
    /// как в оповещениях.
    private func width(for line: RoadSketch.Line) -> CGFloat {
        strokeScale * base(for: line) * zoomWidth
    }

    /// Поправка ширины на охват.
    ///
    /// Толщины заданы в пунктах, то есть НЕ в метрах, и это правильно: дорога,
    /// честно суженная вместе с масштабом, на семистах метрах стала бы волосом.
    /// Но и обратное неверно — при неизменных пунктах город на широком охвате
    /// превращается в толстые макароны, где все улицы слиплись. Степень 0.22
    /// — компромисс: на минимальном охвате единица, на максимальном около
    /// семи десятых, и зум начинает ощущаться зумом.
    private var zoomWidth: CGFloat {
        let ratio = RoadSketch.minSpanMeters / max(RoadSketch.minSpanMeters, scene.spanBucket)
        return CGFloat(min(1, max(0.62, pow(ratio, 0.22))))
    }

    private func base(for line: RoadSketch.Line) -> CGFloat {
        guard line.isDetailed else { return 9 }
        // Схлопнутая раздельная — это две проезжие части в одной оси, и
        // рисовать её шириной одной значило бы сузить проспект вдвое ровно
        // на том охвате, где он главный ориентир.
        if line.isDual { return classWidth(line.kind) * 1.55 }
        return classWidth(line.kind)
    }

    private func classWidth(_ kind: RoadClass) -> CGFloat {
        switch kind {
        case .motorway, .trunk: return 15
        case .primary:          return 12
        case .secondary:        return 10
        case .tertiary:         return 8
        case .residential:      return 6
        case .service:          return 4
        case .pedestrian, .unknown: return 3
        }
    }

    /// Тон полотна: настоящий асфальт, а не белая линия с прозрачностью.
    /// Крупные дороги светлее и теплее, дворы холоднее и темнее; тоннель
    /// приглушён — он «под землёй». Незнающий класса источник получает один
    /// средний тон.
    private func fill(for line: RoadSketch.Line) -> Color {
        if line.level < 0 { return SketchPalette.asphaltTunnel }
        guard line.isDetailed else { return SketchPalette.asphaltUnknown }
        return SketchPalette.asphalt(line.kind)
    }

    /// Шевроны направления на односторонней: каждые ~90 пт, остриём по ходу
    /// точек. Редкие и бледные: это подсказка, а не разметка.
    private func chevrons(context: inout GraphicsContext, along points: [CGPoint]) {
        guard points.count >= 2 else { return }
        let step: CGFloat = 90
        var nextAt: CGFloat = step / 2
        var travelled: CGFloat = 0
        for index in 1..<points.count {
            let from = points[index - 1], to = points[index]
            let dx = to.x - from.x, dy = to.y - from.y
            let length = hypot(dx, dy)
            guard length > 0.5 else { continue }
            while nextAt <= travelled + length {
                let f = (nextAt - travelled) / length
                let tip = CGPoint(x: from.x + dx * f, y: from.y + dy * f)
                let ux = dx / length, uy = dy / length      // по ходу
                let px = -uy, py = ux                        // поперёк
                var chevron = Path()
                chevron.move(to: CGPoint(x: tip.x - ux * 5 - px * 4,
                                         y: tip.y - uy * 5 - py * 4))
                chevron.addLine(to: tip)
                chevron.addLine(to: CGPoint(x: tip.x - ux * 5 + px * 4,
                                            y: tip.y - uy * 5 + py * 4))
                context.stroke(chevron, with: .color(SketchPalette.chevron),
                               style: .init(lineWidth: 1.8, lineCap: .round,
                                            lineJoin: .round))
                nextAt += step
            }
            travelled += length
        }
    }
}
