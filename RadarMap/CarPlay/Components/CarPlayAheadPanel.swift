//
//  CarPlayAheadPanel.swift
//  RadarMap
//
//  Лента «что впереди» справа от схемы: вертикальная шкала на два километра,
//  на ней точки камер, снизу — я.
//
//  Читается снизу вверх, как дорога: ближняя камера у нижнего края, дальняя —
//  у верхнего. Это единственный элемент экрана машины, отвечающий на вопрос
//  «а что после этой», и потому он не дублирует док: там ближайшая дистанция,
//  здесь — плотность впереди.
//
//  Отбор — CarPlayAhead (чистый, с тестами). Пересчёт — не в body: список
//  обновляется на тике геолокации через собственную @Observable модель с
//  гейтом по пройденному расстоянию, иначе каждый фикс перебирал бы окрестные
//  камеры и переоценивал дерево.
//

import CoreLocation
import MapKit
import SwiftUI

struct CarPlayAheadPanel: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = AheadModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ribbon
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surface.opacity(0.97),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(Theme.stroke, lineWidth: 1))
        .onChange(of: env.location.locationTick) { model.refresh(env) }
        .onAppear { model.refresh(env) }
        .accessibilityHidden(true)   // док озвучен, лента — картинка к нему
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.forward")
                .font(.rounded(13, .bold))
                .foregroundStyle(Theme.accent)
            Text("Впереди")
                .font(.rounded(16, .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
            if let summary = CarPlayAhead.summary(model.items) {
                Text(summary)
                    .font(.rounded(13, .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Сама лента

    @ViewBuilder
    private var ribbon: some View {
        if model.items.isEmpty {
            empty
        } else {
            ribbonBody
                // Курс потерян (встали на светофоре): рисуем последнее
                // известное приглушённо — как схема. Раньше лента схлопывалась
                // в «Ждём движения» на каждой остановке и разворачивалась
                // обратно — мигание на ровном месте.
                .opacity(model.isStale ? 0.45 : 1)
                .animation(.easeOut(duration: 0.4), value: model.isStale)
        }
    }

    private var ribbonBody: some View {
            GeometryReader { geometry in
                let height = geometry.size.height
                let travel = max(1, height - Self.rowHeight)
                // Минимальный зазор в долях ленты — высота строки, переведённая
                // в те же единицы. Считаем от геометрии, а не константой:
                // экраны машин разной высоты, и на низком строки сходятся
                // раньше.
                let placed = CarPlayAhead.spread(model.items,
                                                 minGap: Self.rowHeight / travel)
                ZStack(alignment: .bottomLeading) {
                    scale(height: height)
                    ForEach(placed) { item in
                        marker(item)
                            // Доля ленты → точка по вертикали. Отступ снизу
                            // равен высоте строки: иначе ближняя камера
                            // наполовину уезжает за край.
                            .offset(y: -travel * item.fraction)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
    }

    /// Высота строки ленты: значок 30 плюс воздух. От неё же считается
    /// минимальный зазор между метками.
    private static let rowHeight: CGFloat = 44

    /// Ось с делениями.
    ///
    /// Деления обязательны, и это не украшение. Шкала здесь ПОСТОЯННАЯ — два
    /// километра всегда, — и это сделано намеренно: положение точки означает
    /// одно и то же в любой момент, а не растягивается под текущий набор камер.
    /// Плата за честность в том, что при дальних камерах низ ленты пуст, и без
    /// делений эта пустота читается как несработавшая вёрстка. С делениями она
    /// читается как сообщение: до первого штриха чисто.
    private func scale(height: CGFloat) -> some View {
        let travel = max(1, height - Self.rowHeight)
        return ZStack(alignment: .bottomLeading) {
            Capsule()
                .fill(Theme.stroke)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .padding(.leading, 12)

            // Штрихи без чисел — только ритм.
            //
            // Подписанные деления пробовал дважды и оба раза убрал: сперва они
            // встали ровно под подписи камер (восемь чисел в колонке шириной с
            // ладонь), потом подпись масштаба у вершины села на верхнюю метку.
            // Числа здесь и не нужны: у каждой камеры своё написано рядом, а в
            // шапке — до какой дальше всего. Штрихи же говорят единственное,
            // ради чего они тут: у ленты есть масштаб, и пустота внизу — это
            // «до первого штриха чисто», а не несработавшая вёрстка.
            ForEach(Self.ticks, id: \.self) { metres in
                Rectangle()
                    .fill(Theme.stroke)
                    .frame(width: 11, height: 1.5)
                    .padding(.leading, 8)
                    .offset(y: -travel * (metres / CarPlayAhead.rangeMeters)
                            - Self.rowHeight / 2)
            }

            // «Я» — основание шкалы.
            Circle()
                .fill(Theme.accent)
                .frame(width: 11, height: 11)
                .padding(.leading, 8)
                .shadow(color: Theme.accent.opacity(0.7), radius: 6)
        }
    }

    /// Штрихи шкалы. Через полкилометра: чаще — рябь, реже — не за что
    /// зацепиться глазом. Двух километров в списке нет: там стоит подпись
    /// масштаба, и штрих под ней был бы вторым обозначением одного и того же.
    private static let ticks: [CLLocationDistance] = [500, 1000, 1500]

    /// Иерархия «эта — следующая» держится размером и весом, а не только
    /// цветом: с торпеды 20 против 16 почти не различалось, 22 против 15 —
    /// различается мгновенно.
    private func marker(_ item: CarPlayAhead.Item) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(item.isTarget ? Theme.danger : item.kind.tint)
                    .frame(width: item.isTarget ? 34 : 24,
                           height: item.isTarget ? 34 : 24)
                Image(systemName: item.kind.symbolName)
                    .font(.rounded(item.isTarget ? 15 : 11, .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: (item.isTarget ? Theme.danger : .black).opacity(0.55), radius: 6)

            VStack(alignment: .leading, spacing: 0) {
                Text(Formatting.distance(item.distance))
                    .font(.rounded(item.isTarget ? 22 : 15, item.isTarget ? .heavy : .bold)
                        .monospacedDigit())
                    .foregroundStyle(item.isTarget ? Theme.danger : Theme.textPrimary)
                    .contentTransition(.numericText())
                Text(item.kind.shortName)
                    .font(.rounded(13, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 1)
        .frame(height: 40, alignment: .center)
        .animation(.easeOut(duration: 0.3), value: item.distance)
    }

    /// Пусто — это тоже ответ, и хороший. Но сказать его надо так, чтобы он не
    /// читался как сломанный экран.
    ///
    /// Два состояния, и путать их нельзя. «Впереди чисто» — это утверждение, и
    /// зелёный щит под ним честен: мы посмотрели и ничего не нашли. «Ждём
    /// движения» — не утверждение, а признание, что смотреть пока не с чем;
    /// зелёный щит там обещал бы чистую дорогу, которую никто не проверял.
    /// Второй строки в этом состоянии нет намеренно: схема слева уже написала
    /// ровно то же самое, а повторённое дважды объяснение читается как сбой.
    @ViewBuilder
    private var empty: some View {
        if env.location.currentCourse < 0 {
            VStack(spacing: 10) {
                Image(systemName: "location.north.line")
                    .font(.rounded(26, .medium))
                    .foregroundStyle(Theme.textTertiary)
                Text("Ждём движения")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.rounded(30, .medium))
                    .foregroundStyle(Theme.success.opacity(0.85))
                Text("Впереди чисто")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text("Камер в двух километрах нет")
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Пересчёт ленты вне body.
///
/// Гейт двойной и оба нужны: по расстоянию — потому что стоящая в пробке
/// машина иначе перебирала бы окрестность каждую секунду впустую; по ревизии
/// стора — потому что приехавшая отметка водителей обязана появиться на ленте
/// сразу, а не через полсотни метров.
@Observable
final class AheadModel {

    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей:
    /// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor изолирует КАЖДЫЙ класс, а не
    /// только помеченный @MainActor, и синтезированный isolated deinit ведёт
    /// к свободе указателя, который никто не выделял (см. MapState).
    nonisolated deinit {}
    private(set) var items: [CarPlayAhead.Item] = []
    /// Курс потерян (стоим): лента держит последнее известное приглушённо,
    /// вместо того чтобы схлопнуться и мигать на каждом светофоре.
    private(set) var isStale = false
    /// Кандидаты последнего отбора. Дорогая часть — перебор окрестности и
    /// коридор — идёт по гейту, а дистанции у этой горстки пересчитываются
    /// каждым тиком: иначе лента отстаёт от дока на весь шаг гейта, и на
    /// экране рядом стоят два разных числа про одну камеру.
    private var selected: [Camera] = []
    private var lastCoordinate: CLLocationCoordinate2D?
    private var lastCourse: CLLocationDegrees = -1
    private var lastRevision = -1

    func refresh(_ env: AppEnvironment) {
        guard let coordinate = env.location.currentCoordinate,
              env.location.currentCourse >= 0 else {
            // Не чистим: то, что было впереди секунду назад, впереди и стоит —
            // машина на светофоре никуда не делась. Честность обеспечивает
            // приглушение, как у схемы.
            if !items.isEmpty, !isStale { isStale = true }
            return
        }
        if isStale { isStale = false }
        let course = env.location.currentCourse
        let revision = env.cameras.revision

        let moved = lastCoordinate.map {
            GeoMath.fastDistance($0.latitude, $0.longitude,
                                 coordinate.latitude, coordinate.longitude)
        } ?? .greatestFiniteMagnitude
        let turned = abs(course - lastCourse)
        if moved >= AppConfig.carPlayAheadStepMeters
            || turned >= AppConfig.carPlayAheadCourseStepDegrees
            || revision != lastRevision {
            lastCoordinate = coordinate
            lastCourse = course
            lastRevision = revision
            // Окрестность берём из грид-индекса, а не сканом базы: радиус ленты
            // плюс запас на диагональ ячейки.
            let span = (CarPlayAhead.rangeMeters * 2.4) / 111_000
            let region = MKCoordinateRegion(center: coordinate,
                                            span: MKCoordinateSpan(latitudeDelta: span,
                                                                   longitudeDelta: span))
            selected = env.cameras.cameras(in: region, limit: AppConfig.carPlayAheadScanLimit)
        }

        // Дёшево и каждым тиком: у selected обычно единицы элементов.
        items = CarPlayAhead.items(cameras: selected, from: coordinate, course: course,
                                    targetID: env.location.nearestCamera?.id) { camera in
            env.location.isRelevantAhead(camera, from: coordinate)
        }
    }
}
