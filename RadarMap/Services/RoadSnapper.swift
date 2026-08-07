//
//  RoadSnapper.swift
//  RadarMap
//
//  Прижим КАРТИНКИ к оси дороги. Только картинки.
//
//  GPS гуляет вбок на 5–15 м, и точка на карте плавает по газонам и дворам,
//  хотя машина едет по полосе. Настоящие навигаторы прижимают отображаемую
//  позицию к оси дороги — это самый заметный признак «дорогого» навигатора.
//  Геометрия дорог у нас уже лежит на телефоне (индекс лимитов), и ближайшую
//  точку полотна отдаёт ТОТ ЖЕ проход, что ищет лимит (LimitIndex.RoadHit), —
//  снап не стоит ни одного лишнего запроса на тике.
//
//  ГРАНИЦА ПРИМЕНЕНИЯ — жёсткая: снап питает схему приборки и ведение камеры
//  карты. Он НИКОГДА не питает гейты оповещений, запись проездов или трек
//  поездки: прижать сырую координату к дороге значило бы подменить измерение
//  предположением ровно там, где решается «глушить или предупреждать» и
//  «записывать ли проезд». Пайплайн оповещений работает по сырому фиксу.
//
//  Гистерезис: прилипаем ближе 22 м, держимся до 35. Без него точка на границе
//  мигала бы между «на дороге» и «рядом» от каждого метра шума — а мигание
//  читается как поломка. Съезд во двор рвёт снап честно: 35 м — меньше
//  половины квартала, дальше картинка снова живёт по сырому GPS.
//
//  Чистая структура, время и данные приходят параметрами — покрыта
//  RoadSnapperTests.
//

import CoreLocation

nonisolated struct RoadSnapper {

    /// Прилипнуть: мы на этой дороге почти наверняка (ширина полосы + шум GPS).
    static let engageMeters: Double = 22
    /// Держаться: уже прилипли и шум не должен отрывать.
    static let holdMeters: Double = 35
    /// Подменять курс курсом дороги можно только при почти совпадении:
    /// в манёвре (поворот, перестроение через двор) курс дороги — враньё.
    static let courseBlendMaxAngle: Double = 20

    /// Что показывать. `course` nil — курс дороги не подменяет наш
    /// (расходимся с осью больше допуска — идёт манёвр).
    struct Snapped: Equatable {
        var coordinate: CLLocationCoordinate2D
        var courseDegrees: Double?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.courseDegrees == rhs.courseDegrees
        }
    }

    private(set) var isSnapped = false

    /// Тик: дорога последнего матчинга (или nil — матчинг её не нашёл).
    /// Возвращает, что рисовать; nil — рисуем сырой фикс.
    mutating func update(course: CLLocationDirection,
                         hit: LimitIndex.RoadHit?) -> Snapped? {
        guard let hit else {
            isSnapped = false
            return nil
        }
        let limit = isSnapped ? Self.holdMeters : Self.engageMeters
        guard hit.distanceMeters <= limit else {
            isSnapped = false
            return nil
        }
        isSnapped = true

        // Сегмент недирекционный: из двух направлений оси берём ближнее к
        // нашему курсу — и подменяем курс только при почти полном совпадении.
        var roadCourse: Double?
        if course >= 0 {
            let ahead = hit.bearingDegrees
            let back = (ahead + 180).truncatingRemainder(dividingBy: 360)
            let candidate = GeoMath.angleDifference(course, ahead)
                <= GeoMath.angleDifference(course, back) ? ahead : back
            if GeoMath.angleDifference(course, candidate) <= Self.courseBlendMaxAngle {
                roadCourse = candidate
            }
        }
        return Snapped(coordinate: hit.coordinate, courseDegrees: roadCourse)
    }

    mutating func reset() {
        isSnapped = false
    }
}
