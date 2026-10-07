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
    /// Сколько файлов окрестности ещё едет. Ноль — карта полная.
    ///
    /// Молчаливая деградация читается как поломка: пустая земля вместо города
    /// — это «приложение сломалось», а не «сейчас догрузится». Признак нужен
    /// самый тихий: не плашка на пол-экрана, а строка у линейки масштаба.
    var loading: Int = 0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // «Я» стоит по ВИДИМОЙ части, а не по всей высоте: панели хоста
            // забирают себе четверть экрана, и проекция обязана считать от
            // того прямоугольника, в который смотрят.
            let pivot = CGPoint(x: size.width / 2,
                                y: size.height * state.insets.meY)
            // Пунктов на метр растра: по высоте вид покрывает spanBucket метров.
            let k = size.height / scene.spanBucket
            // Сторона квадрата растра: круг видимости вокруг «я» при любом
            // повороте (до дальнего угла вида), с запасом на сжатие
            // scaleEffect (≤ 1/bucketRatio) и на дрейф до пересборки растра.
            let viewRadius = hypot(size.width / 2,
                                   size.height * max(state.insets.meY,
                                                     1 - state.insets.meY))
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
                if cursor.isAway {
                    // Машина ушла за край. Стрелка «я», которой не видно, хуже
                    // отсутствующей: вместо неё по краю показываем, В КАКУЮ
                    // СТОРОНУ осталась машина.
                    //
                    // Проверяется ПЕРВЫМ, раньше курса. Указатель считается от
                    // прижатия к краю, а не от направления движения, — значит
                    // верен и до первого фикса курса. Точка «я», прижатая к
                    // краю на его месте, утверждала бы «машина здесь»: ровно
                    // та ложь, против которой заведён весь осмотр.
                    MeAway(scale: strokeScale, angle: cursor.angle)
                        .frame(width: 30 * strokeScale, height: 30 * strokeScale)
                        .position(cursor.point)
                } else if !state.hasCourse {
                    // Курса нет: ни стрелки, ни конуса — оба обещали бы
                    // направление, которого мы не знаем.
                    MeDot(scale: strokeScale)
                        .frame(width: 22 * strokeScale, height: 22 * strokeScale)
                        .position(cursor.point)
                } else {
                    ViewCone(scale: strokeScale)
                        .frame(width: 92 * strokeScale, height: 170 * strokeScale)
                        .position(x: cursor.point.x,
                                  y: cursor.point.y - 78 * strokeScale)
                        .allowsHitTesting(false)
                    MeCursor(scale: strokeScale)
                        .frame(width: 34 * strokeScale, height: 40 * strokeScale)
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
                loadingChip
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
                        state.viewWidth = size.width
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
                            state.viewWidth = size.width
                            state.beginInspect()
                            state.zoom(by: value.magnification / pinched)
                            pinched = value.magnification
                        }
                        .onEnded { _ in
                            pinched = 1
                            state.endInspect()
                        })
            )
            .onAppear {
                state.viewHeight = size.height
                state.viewWidth = size.width
            }
        }
        .accessibilityHidden(true)   // цифру и сторону рядом VoiceOver уже читает
    }

    /// Мир: растр сцены, пройденный кусок, стрелка манёвра и кольцо тревожной
    /// камеры — под общими transform'ами. Всё это живёт в мировых координатах
    /// и движется вместе с дорогами само.
    private func world(side: CGFloat, k: CGFloat) -> some View {
        ZStack {
            SketchRaster(scene: scene, k: k, strokeScale: strokeScale, trim: trim,
                         close: state.closeReason != nil)
                .equatable()
                .frame(width: side, height: side)
            RouteOverlay(passed: state.passedPath, maneuver: state.maneuverPath,
                         kind: state.maneuverKind, k: k, side: side,
                         strokeScale: strokeScale)
                .equatable()
                .frame(width: side, height: side)
            marks(side: side, k: k)
            labels(side: side, k: k)
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
        .motionAnimation(.easeInOut(duration: 0.55), value: tiltDegrees)
    }

    /// Светофоры и прочие точечные объекты.
    ///
    /// Не в растре, хотя это и дешевле. Растр целиком поворачивается по курсу,
    /// и запечённая в него пиктограмма поворачивается вместе с ним: на
    /// повороте светофор ложится набок, а перевёрнутый значок читается как
    /// поломка рендера. Поэтому объекты едут ОТДЕЛЬНЫМ слоем в тех же
    /// координатах мира — сдвигаются, масштабируются и наклоняются вместе со
    /// схемой, — но каждому возвращён курс, и на экране они стоят прямо.
    ///
    /// Цена честная: это единственный слой, который перерисовывается на тик.
    /// Она мала, потому что мала и величина: в самом плотном кадре центра
    /// Ташкента 7 значков на ближнем плане и 10 на дальнем, а потолок ниже
    /// того, что вообще способно приехать в тайле.
    private func marks(side: CGFloat, k: CGFloat) -> some View {
        ForEach(Array(scene.marks.prefix(RoadSketch.markBudget).enumerated()),
                id: \.offset) { _, mark in
            sketchGlyph(for: mark.kind, scale: strokeScale)
                .rotationEffect(.degrees(state.courseDegrees))
                .position(x: side / 2 + mark.point.x * k,
                          y: side / 2 - mark.point.y * k)
        }
    }

    /// Подписи улиц.
    ///
    /// Тем же слоем, что и значки, и по той же причине: растр целиком
    /// поворачивается по курсу, и запечённая в него строка на повороте
    /// ложилась бы набок, а перевёрнутый текст не читается вовсе. Здесь
    /// каждой подписи возвращён курс — и добавлен её собственный угол вдоль
    /// улицы, приведённый к читаемой половине круга.
    private func labels(side: CGFloat, k: CGFloat) -> some View {
        ForEach(Array(state.labels.prefix(RoadSketch.labelBudget).enumerated()),
                id: \.offset) { _, label in
            Text(label.text)
                // Кегль от ранга: название города обязано читаться раньше
                // названия кишлака, а имя улицы тише обоих. Иерархия размером,
                // а не цветом, — так устроена любая карта, и не из вкуса:
                // цвет на схеме уже занят смыслом (вода, камера, маршрут).
                .font(.roundedFree(11 * strokeScale * label.scale,
                               label.isPlace ? .bold : .semibold))
                .foregroundStyle(label.isPlace ? SketchPalette.placeLabel
                                               : SketchPalette.label)
                // Тень, а не подложка: подложка закрывает полотно, и на
                // перекрёстке подпись прячет ровно то, ради чего смотрят.
                .shadow(color: SketchPalette.ground, radius: 2 * strokeScale)
                .shadow(color: SketchPalette.ground, radius: 2 * strokeScale)
                .lineLimit(1)
                .fixedSize()
                .rotationEffect(.degrees(state.courseDegrees + label.angle))
                .position(x: side / 2 + label.point.x * k,
                          y: side / 2 - label.point.y * k)
        }
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
        // Вид вблизи выпрямляется по той же причине: на пятидесяти метрах
        // перспектива врёт о расстоянии сильнее всего, а именно расстояние
        // там и меряют — до стоп-линии, до поворота, до камеры.
        scene.alertCameraID == nil && !state.isInspecting
            && state.closeReason == nil
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
        // Цвет края — не чёрный, а «то, чем кончается карта»: ночью чернота,
        // днём земля. Чёрная рама на светлой схеме читалась не мягким краем,
        // а грязью по периметру экрана.
        let edge = SketchPalette.edgeFade
        let horizontal = LinearGradient(
            gradient: Gradient(stops: [
                .init(color: edge, location: 0),
                .init(color: .clear, location: 0.13),
                .init(color: .clear, location: 0.87),
                .init(color: edge, location: 1),
            ]), startPoint: .leading, endPoint: .trailing)
        let vertical = LinearGradient(
            gradient: Gradient(stops: [
                .init(color: edge, location: 0),
                .init(color: .clear, location: 0.10),
                .init(color: .clear, location: 0.90),
                .init(color: edge, location: 1),
            ]), startPoint: .top, endPoint: .bottom)
        return Color.clear
            .overlay(horizontal)
            .overlay(vertical)
            .allowsHitTesting(false)
    }

    /// Сколько пунктов схемы закрыто панелями хоста.
    ///
    /// Экранные подсказки схемы обязаны стоять НАД панелями, а не под ними:
    /// имя улицы и линейка масштаба прижимались к нижнему краю экрана, то
    /// есть прятались под панелью поездки и не показывались никогда, а ряд
    /// полос — под карточкой скорости.
    private var topCover: CGFloat { CGFloat(state.insets.safeTop) * state.viewHeight }
    private var bottomCover: CGFloat { CGFloat(state.insets.safeBottom) * state.viewHeight }

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
                        .font(.roundedFree(15 * strokeScale, .bold))
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
            .padding(.top, 6 * strokeScale + topCover)
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
                .font(.roundedFree(13 * strokeScale, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10 * strokeScale)
                .padding(.vertical, 4 * strokeScale)
                .background(Color.black.opacity(0.55), in: Capsule())
                .frame(maxWidth: 220 * strokeScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 14 * strokeScale + bottomCover)
                .allowsHitTesting(false)
                .transition(.opacity)
                .motionAnimation(.easeInOut(duration: 0.35), value: street)
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
                    .font(.roundedFree(15 * strokeScale, .semibold))
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
            .motionAnimation(.easeOut(duration: 0.25), value: state.isInspecting)
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
                .font(.roundedFree(11 * strokeScale, .bold))
                .foregroundStyle(Theme.danger.opacity(0.9))
                .offset(y: -3 * strokeScale)
                .rotationEffect(.degrees(-state.courseDegrees))
            Text("С")
                .font(.roundedFree(8 * strokeScale, .heavy))
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
    /// «Карта загружается» — тихо, у нижней кромки, и только пока едет.
    ///
    /// Считаем ТАЙЛЫ, а не проценты: процент требует знать конечный объём,
    /// а он меняется от каждого движения вида. Число файлов честно и не врёт.
    @ViewBuilder
    private var loadingChip: some View {
        if loading > 0 {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.textTertiary)
                Text("Карта загружается")
                    .font(.rounded(11 * max(1, strokeScale * 0.9), .medium))
                    .foregroundStyle(Theme.textTertiary)
                Text(String(loading))
                    .font(.rounded(11 * max(1, strokeScale * 0.9), .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.55),
                        in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: .bottomLeading)
            .padding(.leading, 30)
            .padding(.bottom, 34 * strokeScale + bottomCover)
            .allowsHitTesting(false)
            .transition(.opacity)
            .motionAnimation(.easeOut(duration: 0.2), value: loading > 0)
        }
    }

    /// Подпись деления линейки.
    ///
    /// Своя, а не общая Formatting.distance: та пишет «1,0 км» — верно для
    /// расстояния до камеры, где десятая доля значит сорок метров подхода, и
    /// нелепо для круглого деления линейки. Здесь числа всегда круглые, и
    /// запятая с нулём — только шум.
    static func scaleLabel(_ meters: Double) -> String {
        meters < 1000
            ? String(format: String(localized: "%@ м"), String(Int(meters.rounded())))
            : String(format: String(localized: "%@ км"),
                     String(Int((meters / 1000).rounded())))
    }

    private func scaleBar(height: CGFloat) -> some View {
        let meters = RoadSketch.scaleBarMeters(forSpan: state.spanMeters)
        let width = CGFloat(meters) * height / CGFloat(state.spanMeters)
        return HStack(spacing: 6) {
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: width, height: 2 * strokeScale)
            Text(Self.scaleLabel(meters))
                .font(.rounded(11 * max(1, strokeScale * 0.9), .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .bottomLeading)
        .padding(.leading, 30)
        .padding(.bottom, 8 * strokeScale + bottomCover)
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
/// Курсор машины. Не приватный: его рисуют ДВА рендера — своя схема и карта
/// на движке, — и рисовать «я» по-разному в двух подложках значило бы менять
/// вместе с подложкой самый важный предмет на экране.
struct MeCursor: View {
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
            // Тень — только у неподвижного знака. Висела на всём ZStack вместе
            // с пульсом, и компоновщик пересчитывал размытую тень расходящегося
            // кольца каждый кадр (docs/perf_audit_2026-10-07.md).
            ZStack {
                Circle()
                    .fill(tint.opacity(0.18))
                    .frame(width: 40 * scale, height: 40 * scale)
                Circle()
                    .fill(Theme.danger)
                    .frame(width: 22 * scale, height: 22 * scale)
                    .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5 * scale))
                Image(systemName: "camera.fill")
                    .font(.roundedFree(10 * scale, .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.6), radius: 3 * scale)
        }
        .onAppear {
            withMotion(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

/// Мы здесь, но куда смотрим — неизвестно.
///
/// Точка, а не стрелка, и это единственно честная форма: стрелка обещает
/// направление, а до первого движения его нет. Кольцо вокруг — та же
/// «неуверенность», что у синей точки системных карт.
private struct MeDot: View {
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Circle()
                .fill(SketchPalette.meBody.opacity(0.22))
                .frame(width: 44 * scale, height: 44 * scale)
            Circle()
                .fill(LinearGradient(colors: [SketchPalette.meTop,
                                              SketchPalette.meBody],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5 * scale))
        }
        .shadow(color: .black.opacity(0.55), radius: 3 * scale)
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
                .font(.roundedFree(13 * scale, .bold))
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

    /// Длина ломаной в тех же единицах, в каких лежат её точки.
    static func length(of points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        var total: CGFloat = 0
        for index in 1..<points.count {
            total += hypot(points[index].x - points[index - 1].x,
                           points[index].y - points[index - 1].y)
        }
        return total
    }

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
    /// Схема вблизи: подход к манёвру, камера рядом, двор. Растр рисует
    /// подробнее — разметку на двухполосной, где на обзоре её нет.
    ///
    /// Флагом, а не ссылкой на состояние: растр кэшируется по равенству, и
    /// живое состояние сделало бы кэш бесполезным — он пересобирался бы на
    /// каждый тик.
    var close: Bool = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.k == rhs.k && lhs.strokeScale == rhs.strokeScale
            && lhs.trim == rhs.trim && lhs.close == rhs.close
            && lhs.scene == rhs.scene
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
                    // Дом с известной этажностью получает объём: сдвинутая
                    // копия контура под ним читается как тень высоты. Дом без
                    // этажности остаётся плоским пятном — выдуманная высота
                    // превращает город в макет из одинаковых коробок, а
                    // водитель, поймавший выдумку, перестаёт верить и правде.
                    //
                    // Тень идёт ВНИЗ ЭКРАНА, то есть «на водителя»: растр
                    // повёрнут по курсу, и постоянное направление тени в
                    // мировых координатах крутилось бы вместе с городом.
                    if area.kind == .house, area.levels > 0 {
                        let lift = min(CGFloat(area.levels), 12) * 0.7 * strokeScale
                        var below = shape
                        below.closeSubpath()
                        context.fill(
                            below.offsetBy(dx: 0, dy: lift),
                            with: .color(SketchPalette.houseShadow))
                    }
                    context.fill(closed, with: .color(areaFill(area)))
                    // Контур дома. Самое дешёвое из всего, что делает
                    // застройку застройкой: девяносто домов в кадре без
                    // контуров сливаются в одно серое поле — именно это и
                    // было на снимках живой поездки.
                    if area.kind == .house {
                        context.stroke(closed, with: .color(SketchPalette.houseEdge),
                                       style: .init(lineWidth: 0.7 * strokeScale,
                                                    lineJoin: .round))
                    }
                    // Кромка полотна — бордюр. Только у полотна: у площади
                    // перекрёстка её нет и в жизни, а обведи мы её — на
                    // перекрёстке появился бы контур поперёк проезжей части,
                    // то есть ровно то, чего мы избегали швами.
                    // Бордюр — и у полотна, и у разделительной: у островка он
                    // есть в жизни, и без него полоса читается провалом в
                    // асфальте, а не поднятой землёй.
                    if area.kind == .road || area.kind == .median {
                        context.stroke(closed, with: .color(SketchPalette.kerb),
                                       style: .init(lineWidth: 1.1 * strokeScale,
                                                    lineJoin: .round))
                    }
                    if area.kind == .water {
                        // Кромка воды: без неё пруд на тёмном фоне читается
                        // дырой, а не поверхностью.
                        context.stroke(closed, with: .color(SketchPalette.waterEdge),
                                       style: .init(lineWidth: 1.2 * strokeScale,
                                                    lineJoin: .round))
                    }
                } else {
                    context.stroke(shape, with: .color(areaFill(area)),
                                   style: .init(lineWidth: areaWidth(area.kind),
                                                lineCap: .round, lineJoin: .round,
                                                dash: areaDash(area.kind)))
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
            // Легло ли готовое полотно.
            //
            // Если да — штрихи сети по земле не рисуются вовсе: линия поверх
            // залитого полотна это вторая дорога поверх первой, и заметно это
            // именно на перекрёстке, где их края расходятся.
            //
            // Мосты и тоннели остаются штрихами при любом раскладе: у них своя
            // подложка и свой пунктир, и по ним видно, что одно проходит над
            // другим. Полотно этого не показывает — оно плоское.
            // Полотно легло ЦЕЛИКОМ — спрашиваем у сцены, а не считаем сами.
            //
            // Здесь стояло «есть ли хоть одна фигура полотна», и в перегреве
            // это было ложью: бюджет резал поверхность посередине, штрихи
            // сети выключались целиком, и на экране оставались куски асфальта
            // без перекрёстков и без линий между ними — рваные дороги.
            let paved = scene.hasPavement

            let byLevel = Dictionary(grouping: scene.network.filter { $0.points.count >= 2 },
                                     by: \.level)
            for level in byLevel.keys.sorted() {
                let lines = byLevel[level]!
                // Мост отбивается тёмной «подложкой» шире самой линии: она
                // разрывает то, что проходит под ним, и пересечение читается
                // как развязка, а не как перекрёсток.
                if level > 0 {
                    for line in lines {
                        let body = width(for: line)
                        let halo = 6 * strokeScale
                        // Подложка ЦВЕТОМ ЗЕМЛИ, а не чёрным.
                        //
                        // Её работа — показать, что под мостом ничего нет, и
                        // «ничего нет» на схеме выглядит как земля. Чистый
                        // чёрный на земле, которая не чёрная, читается дырой в
                        // полотне — на снимках с приборки это ровно то самое
                        // «пустое место посреди дороги».
                        //
                        // И только там, где мост ДЛИННЕЕ своей же каймы: на
                        // коротком куске от подложки остаётся один ореол, а
                        // самого моста не видно вовсе. Такие куски в развязке
                        // сплошь — съезды режутся на узлах по два-три метра.
                        // Длина — в ПУНКТАХ, как и ширина: точки линии лежат
                        // в метрах сцены, k переводит их в экранные пункты.
                        // Сравнивать метры с пунктами — та же ошибка, что
                        // однажды раздула оболочку узла вчетверо.
                        guard SketchGeometry.length(of: line.points) * k
                                > body + halo * 2 else { continue }
                        context.stroke(path(line.points),
                                       with: .color(SketchPalette.ground),
                                       style: .init(lineWidth: body + halo,
                                                    lineCap: .butt, lineJoin: .round))
                    }
                }
                // Кайма ТЕМНЕЕ земли: полотно читается лежащим на ней, а две
                // параллельные улицы в пятнадцати метрах не сливаются в одну
                // широкую. Тоннелям каймы нет — они и так пунктиром «под
                // землёй».
                for line in lines where level >= 0 && !(paved && level == 0) {
                    var shape = path(line.points)
                    if line.isRing { shape.closeSubpath() }
                    context.stroke(shape,
                                   with: .color(SketchPalette.casing),
                                   style: .init(lineWidth: width(for: line) + 3.5 * strokeScale,
                                                lineCap: .butt, lineJoin: .round))
                }
                for line in lines where !(paved && level == 0) {
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
                // Разделительные между полосами — ДО заглушек узлов, и это не
                // порядок ради порядка. Заглушка кладёт в узле диск цветом
                // асфальта, то есть стирает разметку ровно там, где ей и
                // положено обрываться: перед перекрёстком. Нарисованные после
                // неё, разделительные шли бы сквозь перекрёсток насквозь.
                for line in lines where trim && level >= 0 {
                    var shape = path(line.points)
                    if line.isRing { shape.closeSubpath() }
                    laneDividers(context: &context, line: line, shape: shape)
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
                // Заглушки узлов нужны только там, где сеть рисуется
                // штрихами. Пришло полотно — площадь перекрёстка уже посчитана
                // сборкой и лежит отдельной фигурой; считать её ещё и здесь
                // значит рисовать одно и то же дважды, разными способами.
                var nodes: [Int64: SketchNode] = [:]
                for line in lines where !paved {
                    guard line.points.count >= 2 else { continue }
                    let lineWidth = width(for: line)
                    let lineColor = fill(for: line)
                    let first = line.points[0]
                    let second = line.points[1]
                    let last = line.points[line.points.count - 1]
                    let prior = line.points[line.points.count - 2]
                    for (point, inner) in [(first, second), (last, prior)] {
                        let key = Int64((point.x).rounded()) &* 1_000_003
                            &+ Int64((point.y).rounded())
                        var node = nodes[key] ?? SketchNode(point: point,
                                                            width: lineWidth,
                                                            color: lineColor)
                        node.arms.append(SketchNode.Arm(towards: inner,
                                                        width: lineWidth / k))
                        node.ends += 1
                        if lineWidth > node.width {
                            node.width = lineWidth
                            node.color = lineColor
                        }
                        // Ширина в МЕТРАХ, а не в пунктах.
                        //
                        // Точки узла живут в координатах сцены (метры), а
                        // width(for:) отдаёт пункты — их и рисуют. Смешать их
                        // здесь значит раздуть оболочку в k раз, где k —
                        // пунктов на метр: на ближнем охвате это вчетверо, и
                        // перекрёсток превращается в кляксу поверх кварталов.
                        node.edges.append(contentsOf:
                            SketchNode.edgePoints(at: point, towards: inner,
                                                  width: lineWidth / k))
                        nodes[key] = node
                    }
                }
                for node in nodes.values where node.ends >= 2 {
                    // Три конца и больше — настоящий перекрёсток, и закрывает
                    // его ПЛОЩАДЬ между кромками, а не диск.
                    //
                    // Диск здесь стоял с самого начала и на прямом стыке двух
                    // кусков работает. На перекрёстке — нет, и это замерено на
                    // панели, где была та же беда: круглые торцы вместо
                    // срезанных дали 31 дырку против 30, в пределах шума.
                    // Круг закрывает лишь то, что укладывается в его радиус, а
                    // площадь между кромками дорог разной ширины, сходящихся
                    // под разными углами, не принадлежит ни одной осевой.
                    if node.ends >= 3,
                       let hull = SketchNode.hull(node.edges.map(at)),
                       hull.count >= 3 {
                        var shape = Path()
                        shape.move(to: hull[0])
                        for point in hull.dropFirst() { shape.addLine(to: point) }
                        shape.closeSubpath()
                        context.fill(shape, with: .color(node.color))
                        continue
                    }
                    let centre = at(node.point)
                    let radius = node.width / 2
                    context.fill(Path(ellipseIn: CGRect(x: centre.x - radius,
                                                        y: centre.y - radius,
                                                        width: radius * 2,
                                                        height: radius * 2)),
                                 with: .color(node.color))
                }

                // Фаска подхода.
                //
                // В жизни улица расширяется перед перекрёстком: полоса
                // поворота, скруглённый бордюр, карман. Без неё улица
                // втыкается в проспект прямоугольным торцом, и перекрёсток
                // читается стыком двух лент, а не местом, куда сворачивают.
                //
                // Идёт ПОСЛЕ оболочки узла и тем же цветом: сначала должно
                // стать видно, что швов нет, и только потом — что подход
                // расширяется.
                for node in nodes.values where node.ends >= 3 {
                    for trapeze in node.flares() {
                        var shape = Path()
                        let screen = trapeze.map(at)
                        shape.move(to: screen[0])
                        for point in screen.dropFirst() { shape.addLine(to: point) }
                        shape.closeSubpath()
                        context.fill(shape, with: .color(node.color))
                    }
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

            // Краска на асфальте — ПОСЛЕДНИЙ дорожный слой: она лежит поверх
            // полотна, разделительных и осевой, потому что в жизни лежит
            // поверх асфальта. Уровня у неё нет: зебра на мосту рисуется вместе
            // с мостом, а под мостом её и не бывает.
            for marking in scene.markings {
                paint(context: &context, marking: marking, at: at)
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
                let isAlert = dot.id == scene.alertCameraID
                cameraGaze(dot, isAlert: isAlert, in: &context, at: at)
                if let symbol = context.resolveSymbol(
                    id: SketchSymbol.camera(alert: isAlert)) {
                    context.draw(symbol, at: at(dot.point))
                }
            }
        }
        symbols: {
            // Пиктограммы объявляются ОДИН раз на весь растр, а не рисуются
            // по одной на каждый объект: Canvas растеризует символ единожды и
            // дальше только ставит его копии.
            CameraDotGlyph(scale: strokeScale, isAlert: false)
                .tag(SketchSymbol.camera(alert: false))
            CameraDotGlyph(scale: strokeScale, isAlert: true)
                .tag(SketchSymbol.camera(alert: true))
        }
        .drawingGroup()   // одна текстура: transform'ы крутят её без перерисовки
    }

    /// Куда смотрит камера.
    ///
    /// Главный объект приложения был нарисован беднее всех — кружком, который
    /// ничего не сообщает о том, ловит ли камера ТВОЁ направление. Теперь она
    /// смотрит, и ровно настолько уверенно, насколько мы знаем:
    ///
    /// — есть `dir` (односторонняя дорога, OSM знает направление однозначно) —
    ///   конус в эту сторону: камера ловит тех, кто едет туда;
    /// — есть только ось — створ в обе стороны вдоль оси: «следит вот за этой
    ///   линией», без стороны;
    /// — нет ничего — ничего и не рисуем.
    ///
    /// Выдуманный конус водитель однажды поймает, и после этого перестанет
    /// верить и правде. Поэтому третий случай — пустой, а не «примерно туда».
    private func cameraGaze(_ dot: RoadSketch.CameraDot, isAlert: Bool,
                            in context: inout GraphicsContext,
                            at place: (CGPoint) -> CGPoint) {
        let reach = (isAlert ? 34 : 20) * strokeScale
        let origin = place(dot.point)
        let tint = isAlert ? SketchPalette.cameraGazeAlert : SketchPalette.cameraGaze

        func wedge(_ degrees: Double, spread: Double) {
            // Азимут отсчитывается от севера по часовой, экран — от оси x
            // против; отсюда −90°.
            let middle = Angle.degrees(degrees - 90)
            var path = Path()
            path.move(to: origin)
            path.addArc(center: origin, radius: reach,
                        startAngle: middle - .degrees(spread / 2),
                        endAngle: middle + .degrees(spread / 2),
                        clockwise: false)
            path.closeSubpath()
            context.fill(path, with: .color(tint))
        }

        if let facing = dot.facing {
            wedge(facing, spread: 54)
        } else if let axis = dot.axis {
            // Ось ненаправленная: рисуем обе стороны — иначе мы утверждаем
            // то, чего в данных нет.
            wedge(axis, spread: 30)
            wedge(axis + 180, spread: 30)
        }
    }

    private func areaFill(_ area: RoadSketch.Area) -> Color {
        // Класс полотна — из самой записи: проспект и двор обязаны отличаться
        // и в заливке, иначе весь город станет одного тона.
        if area.kind == .road, area.roadClass > 0 {
            return SketchPalette.asphalt(RoadTiles.roadClass(code: area.roadClass))
        }
        switch area.kind {
        // Полотно и перекрёсток красятся АСФАЛЬТОМ — тем же, что штрихи сети.
        // Класс приезжает в битах записи; без него взяли бы средний тон и
        // потеряли разницу между проспектом и двором ровно там, где она видна
        // лучше всего.
        case .road, .junction: return SketchPalette.asphaltUnknown
        case .median: return SketchPalette.median
        case .water: return SketchPalette.water
        case .green: return SketchPalette.green
        case .rail:  return SketchPalette.rail
        case .block: return SketchPalette.block
        case .sidewalk: return SketchPalette.sidewalk
        case .house: return SketchPalette.house
        }
    }

    /// Ширина ленты местности. Река лентой шире рельсов: по ширине их и
    /// различают, когда цвет съеден солнцем через лобовое стекло.
    private func areaWidth(_ kind: SketchArea.Kind) -> CGFloat {
        switch kind {
        case .water: return 7 * strokeScale * zoomWidth
        case .rail:  return 2.5 * strokeScale
        case .green, .block: return 3 * strokeScale
        // Тоньше всего на схеме: тротуар — граница асфальта, а не путь.
        case .sidewalk: return 1.6 * strokeScale
        // Поверхность приходит замкнутым контуром и заливается; ширина нужна
        // только на случай вырожденного контура, оставшегося лентой.
        case .road, .junction, .median: return 1.5 * strokeScale
        // Дом приходит замкнутым контуром и заливается; ширина нужна только
        // на случай вырожденного контура, оставшегося лентой.
        case .house: return 1.5 * strokeScale
        }
    }

    /// Штрих ленты местности.
    ///
    /// Тротуар — ПУНКТИРОМ, и это не украшение. Сплошная линия любой толщины
    /// читается проезжей частью: глазу за рулём важна не толщина, а
    /// непрерывность, и тонкая сплошная лента вдоль проспекта выглядела
    /// дублёром. Пунктир проезжей частью не читается никогда — этим приёмом
    /// пешеходные пути отделяют от дорог все карты, и по той же причине.
    ///
    /// Рельсы остаются длинным штрихом: это шпалы, и они длиннее.
    private func areaDash(_ kind: SketchArea.Kind) -> [CGFloat] {
        switch kind {
        case .rail: return [9 * strokeScale, 6 * strokeScale]
        case .sidewalk: return [1.4 * strokeScale, 3.2 * strokeScale]
        default: return []
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
        max(metricWidth(for: line), strokeScale * base(for: line) * zoomWidth)
    }

    /// Зебра и стоп-линия.
    ///
    /// И то и другое — ОДИН отрезок поперёк проезжей части; разница только в
    /// том, чем его обвести. Зебра — толстый штрих с пунктиром ПОПЕРЁК себя:
    /// разрывы пунктира и есть промежутки между полосами зебры, то есть
    /// рисовать каждую полосу отдельным прямоугольником не нужно. Стоп-линия —
    /// тонкий сплошной штрих того же отрезка.
    ///
    /// Ни зебра, ни стоп-линия не масштабируются в пунктах: у них есть
    /// настоящие размеры в метрах, и на схеме они обязаны выглядеть теми же
    /// четырьмя метрами, что и в натуре.
    private func paint(context: inout GraphicsContext, marking: RoadSketch.Marking,
                       at transform: (CGPoint) -> CGPoint) {
        let across = marking.ends
        let width = CGFloat(marking.widthMeters) * k
        // Черта в несколько пунктов — не разметка, а сор в растре.
        guard width >= RoadSketch.markingMinPoints * strokeScale else { return }
        var line = Path()
        line.move(to: transform(across.0))
        line.addLine(to: transform(across.1))

        switch marking.kind {
        case .crossing:
            let stripe = max(RoadSketch.zebraStripeMeters * k,
                             RoadSketch.zebraStripeMinPoints * strokeScale)
            context.stroke(line, with: .color(SketchPalette.marking),
                           style: .init(lineWidth: RoadSketch.zebraDepthMeters * k,
                                        lineCap: .butt,
                                        dash: [stripe, stripe]))
        case .stopLine:
            context.stroke(line, with: .color(SketchPalette.marking),
                           style: .init(lineWidth: max(1.2 * strokeScale,
                                                       RoadSketch.stopLineMeters * k),
                                        lineCap: .butt))
        case .laneArrows:
            arrows(context: &context, marking: marking, at: transform)
        default:
            break
        }
    }

    /// Стрелки полос: по одной на полосу, каждая повёрнута по своему
    /// направлению.
    ///
    /// Стрелки живут в МЕТРАХ, как и всё остальное на асфальте, и раскладка у
    /// них та же, что у разделительных: центр полосы — на полшага внутрь от её
    /// границы. Считать их по ширине проезжей части нельзя — полос ровно
    /// столько, сколько направлений приехало, и это число знает только сервер.
    ///
    /// «Прямо и налево» рисуется ДВУМЯ стрелками из одной точки, а не одной
    /// двусмысленной: водитель читает разметку боковым зрением, и одна фигура
    /// о двух смыслах читается как ошибка.
    private func arrows(context: inout GraphicsContext, marking: RoadSketch.Marking,
                        at transform: (CGPoint) -> CGPoint) {
        let lanes = marking.turns.count
        guard lanes > 0 else { return }
        let lane = CGFloat(marking.widthMeters) / CGFloat(lanes)
        guard lane * k >= RoadSketch.laneDividerMinLanePoints * strokeScale else { return }

        let radians = marking.azimuthDegrees * Double.pi / 180
        // Поперёк дороги — (cos, −sin); вдоль — (sin, cos).
        let across = CGPoint(x: CGFloat(Foundation.cos(radians)),
                             y: CGFloat(-Foundation.sin(radians)))
        let along = CGPoint(x: CGFloat(Foundation.sin(radians)),
                            y: CGFloat(Foundation.cos(radians)))
        let half = CGFloat(marking.widthMeters) / 2
        let length = RoadSketch.arrowMeters

        for (index, turn) in marking.turns.enumerated() {
            let offset = (CGFloat(index) + 0.5) * lane - half
            let base = CGPoint(x: marking.point.x + across.x * offset,
                               y: marking.point.y + across.y * offset)
            for angle in turn.angles {
                context.stroke(arrowPath(from: base, along: along, across: across,
                                         length: length, turn: angle,
                                         transform: transform),
                               with: .color(SketchPalette.marking),
                               style: .init(lineWidth: 1.6 * strokeScale,
                                            lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// Одна стрелка: древко по ходу дороги и остриё, повёрнутое на угол.
    ///
    /// Всё считается в координатах МИРА, а не экрана: схема поворачивается по
    /// курсу, и стрелка, собранная в экранных осях, поехала бы вместе с ним
    /// отдельно от своей полосы.
    private func arrowPath(from base: CGPoint, along: CGPoint, across: CGPoint,
                           length: CGFloat, turn: Double,
                           transform: (CGPoint) -> CGPoint) -> Path {
        func world(_ forward: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: base.x + along.x * forward + across.x * side,
                    y: base.y + along.y * forward + across.y * side)
        }
        let radians = turn * Double.pi / 180
        // Направление острия относительно хода дороги.
        let tipForward = CGFloat(Foundation.cos(radians))
        let tipSide = CGFloat(Foundation.sin(radians))

        let shaft = length * 0.45
        let reach = length * 0.55
        let bend = world(shaft, 0)
        let head = world(shaft + tipForward * reach, tipSide * reach)

        var path = Path()
        path.move(to: transform(world(-length * 0.5, 0)))
        path.addLine(to: transform(bend))
        path.addLine(to: transform(head))

        // Остриё — две коротких черты назад от конца, под углом к его ходу.
        let barb = length * 0.3
        for side in [CGFloat(-1), CGFloat(1)] {
            let backForward = -tipForward * barb * 0.8 + (-tipSide) * side * barb * 0.5
            let backSide = -tipSide * barb * 0.8 + tipForward * side * barb * 0.5
            let wing = CGPoint(x: head.x + along.x * backForward + across.x * backSide,
                               y: head.y + along.y * backForward + across.y * backSide)
            path.move(to: transform(head))
            path.addLine(to: transform(wing))
        }
        return path
    }

    /// Разделительные между полосами.
    ///
    /// Рисуются БЕЗ смещения геометрии, и это главное в приёме. Полоса
    /// шириной 2d, положенная цветом разметки на готовое полотно и тут же
    /// перекрытая асфальтом шириной 2d − t, оставляет ровно две линии на ±d
    /// от оси — то есть пару разделительных. Тот же трюк, что у каймы, и та
    /// же цена: два штриха по уже готовому пути, ни одной новой точки. Честное
    /// смещение ломаной вбок стоило бы (полос − 1) новых ломаных на каждую
    /// дорогу, и это на слое, который и так самый плотный.
    ///
    /// Пунктир задаётся ВНЕШНЕМУ штриху: в его разрывах остаётся асфальт, и
    /// разделительная выходит прерывистой сама собой.
    ///
    /// Порядок ОТ КРАЯ К ЦЕНТРУ обязателен. Широкая полоса закрывает всё, что
    /// лежит внутри неё, и обратный порядок стирал бы уже нарисованное.
    private func laneDividers(context: inout GraphicsContext, line: RoadSketch.Line,
                              shape: Path) {
        guard line.isDetailed else { return }
        let lanes = line.laneCount
        // Вблизи разметка нужна и на двухполосной: там она и есть вся дорога.
        // На обзоре — от трёх полос, иначе на дальнем плане пунктир между
        // двумя полосами сливается с осевой в рябь.
        guard lanes >= (close ? 2 : 3) else { return }
        let full = metricWidth(for: line)
        let lane = full / CGFloat(lanes)
        // Полоса тоньше этого — не разметка, а муар: на схеме останется рябь
        // вместо линий, и читаться она будет как дефект растра.
        guard lane >= RoadSketch.laneDividerMinLanePoints * strokeScale else { return }

        let asphalt = fill(for: line)
        let thickness = 1.1 * strokeScale
        for d in RoadSketch.laneDividerOffsets(lanes: lanes, laneWidth: lane) {
            guard 2 * d > thickness else { continue }
            context.stroke(shape, with: .color(SketchPalette.laneDivider),
                           style: .init(lineWidth: 2 * d + thickness,
                                        lineCap: .butt, lineJoin: .round,
                                        dash: [5 * strokeScale, 7 * strokeScale]))
            context.stroke(shape, with: .color(asphalt),
                           style: .init(lineWidth: 2 * d - thickness,
                                        lineCap: .butt, lineJoin: .round))
        }
    }

    /// Ширина проезжей части В МЕТРАХ, переведённая в точки.
    ///
    /// Это и есть «асфальт» с образца: серое поле, которое видно на настоящей
    /// карте, — не отдельный слой и не полигон, а та же осевая линия,
    /// нарисованная своей настоящей толщиной. Перекрёсток собирается сам из
    /// перекрытия двух широких штрихов, и ни одного пересечения полигонов не
    /// считается ни здесь, ни на сервере.
    ///
    /// Берётся МАКСИМУМ с прежней формулой, а не вместо неё, и порогов по
    /// охвату нет намеренно. На дальнем плане метры сами сходятся с прежними
    /// пунктами в пределах точки (проспект: 22.5 м × 0.47 пт/м ≈ 10.6 пт
    /// против 11.5 пт по классу), поэтому граница костяка не даёт скачка
    /// ширины. А на ближнем — где метры и нужны — они честно шире, и дорога
    /// перестаёт быть ниткой посреди поля.
    ///
    /// Прежняя формула остаётся ПОЛОМ: дорога, честно суженная вместе с
    /// масштабом, на семистах метрах стала бы волосом. Пол не даёт этого ни
    /// двору, ни тротуару.
    ///
    /// Множитель isDual сюда НЕ применяется: полосы сведённой оси сервер уже
    /// сложил (collapse_dual), и второй раз ту же ширину удваивать нельзя.
    private func metricWidth(for line: RoadSketch.Line) -> CGFloat {
        guard line.isDetailed else { return 0 }
        return CGFloat(line.widthMeters) * k
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
