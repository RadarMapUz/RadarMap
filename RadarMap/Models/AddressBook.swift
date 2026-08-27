//
//  AddressBook.swift
//  RadarMap
//
//  Адреса города для поиска БЕЗ СЕТИ.
//
//  Поиск в приложении и так работает — через Apple, и работает хорошо. Но
//  только по сети: в роуминге, в подвале парковки, в тоннеле и на краю
//  покрытия «Куда» просто перестаёт существовать. Свой индекс отвечает всегда
//  и мгновенно, поэтому он первый источник, а не замена.
//
//  Потолок назван честно и замерен на живых данных: в кадре центра Ташкента
//  18 755 объектов с адресом при 54 094 домах — треть. Остальное так и
//  остаётся за Apple, и порядок источников это учитывает.
//
//  Раскладка НЕ тайловая. Адрес ищут там, куда ещё не приехали; окрестность
//  отвечала бы только про то, где стоишь. Поэтому клетка крупная — полградуса,
//  полсотни километров, город целиком, — и весит она немного: весь центр
//  Ташкента это 140 КБ, 630 улиц и 9 743 дома.
//

import CoreLocation
import Foundation

nonisolated struct Address: Sendable, Equatable {
    let street: String
    let house: String
    let point: CLLocationCoordinate2D

    /// Как показать человеку: «Навои, 12».
    var title: String { "\(street), \(house)" }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.street == rhs.street && lhs.house == rhs.house
            && lhs.point.latitude == rhs.point.latitude
            && lhs.point.longitude == rhs.point.longitude
    }
}

nonisolated struct AddressBook: Sendable {

    /// Шаг сетки адресов — 0,5°, как у старого формата тайлов. Полградуса это
    /// полсотни километров: город целиком в одной клетке.
    static let cellDegrees = 0.5

    /// Ключ клетки в подписанном индексе. Считается ровно так же, как на
    /// сервере: смещаем в положительные, чтобы не спорить об округлении.
    static func key(for coordinate: CLLocationCoordinate2D) -> String {
        let row = Int(floor((coordinate.latitude + 90) / cellDegrees))
        let column = Int(floor((coordinate.longitude + 180) / cellDegrees))
        return "\(row)_\(column)_a"
    }

    let addresses: [Address]

    /// Разобрать файл клетки. nil — файл не наш или битый: ответ «адресов
    /// нет» честнее, чем половина списка.
    static func decode(_ data: Data) -> AddressBook? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streets = root["streets"] as? [[String: Any]]
        else { return nil }

        var out: [Address] = []
        for street in streets {
            guard let name = street["n"] as? String,
                  let houses = street["h"] as? [String],
                  let flat = street["p"] as? [NSNumber]
            else { continue }
            // Номеров ровно вдвое меньше, чем чисел координат. Расхождение
            // означает, что адреса разъедутся по чужим домам, — молча брать
            // сколько влезет здесь нельзя.
            guard flat.count == houses.count * 2 else { continue }
            var lat = 0, lon = 0
            for (index, house) in houses.enumerated() {
                let i = index * 2
                if index == 0 {
                    lat = flat[0].intValue
                    lon = flat[1].intValue
                } else {
                    lat += flat[i].intValue
                    lon += flat[i + 1].intValue
                }
                out.append(Address(
                    street: name, house: house,
                    point: CLLocationCoordinate2D(
                        latitude: Double(lat) / RoadTiles.scale,
                        longitude: Double(lon) / RoadTiles.scale)))
            }
        }
        return AddressBook(addresses: out)
    }

    /// Приведение к сравнимому виду.
    ///
    /// Задача не косметическая, и она замерена: из 630 улиц центра Ташкента
    /// 72 % записаны в OSM латиницей и 28 % кириллицей. Водитель пишет на
    /// одном языке — и без приведения не находит большинство города, на каком
    /// бы ни писал.
    ///
    /// Поэтому всё сводится к одной «слабой латинице»:
    /// — кириллица переводится в латиницу;
    /// — `q`→`k`, `x`→`h`, `w`→`v`, `zh`→`j`: узбекская латиница и русская
    ///   транслитерация расходятся ровно в этих буквах («Мустакиллик» против
    ///   «Mustaqillik»);
    /// — `o`→`a`: систематическое расхождение узбекского и русского написания
    ///   («Chilonzor» против «Чиланзар», «Toshkent» против «Ташкент»).
    ///   Проверено на живом файле: без него «Чиланзар» не находится вовсе, а
    ///   с ним число лишних попаданий не растёт.
    static func fold(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text.lowercased() {
            if let latin = cyrillic[character] {
                out += latin
            } else {
                out.append(character)
            }
        }
        out = out.replacingOccurrences(of: "zh", with: "j")
        var loose = ""
        loose.reserveCapacity(out.count)
        for scalar in out.unicodeScalars {
            switch scalar {
            case "q": loose.append("k")
            case "x": loose.append("h")
            case "w": loose.append("v")
            case "o": loose.append("a")
            default:
                if CharacterSet.alphanumerics.contains(scalar) {
                    loose.unicodeScalars.append(scalar)
                } else {
                    loose.append(" ")
                }
            }
        }
        return loose.split(separator: " ").joined(separator: " ")
    }

    private static let cyrillic: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo",
        "ж": "j", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sh",
        "ъ": "", "ы": "i", "ь": "", "э": "e", "ю": "yu", "я": "ya",
        "ў": "o", "қ": "k", "ғ": "g", "ҳ": "h", "ә": "a",
    ]

    /// Слова, которые не сужают поиск.
    ///
    /// «улица», «ko'chasi», «street» стоят у половины улиц города и не
    /// отличают ни одну от другой. Выбрасываем их с ОБЕИХ сторон: иначе
    /// «улица Навои» не находит «Alisher Navoiy ko'chasi», потому что слова
    /// «улица» в нём нет.
    static let noise: Swift.Set<String> = [
        "ulitsa", "ul", "kachasi", "kacha", "kuchasi", "street", "st",
        "praezd", "pereulak", "per", "shasse", "tupik", "massiv", "mahalla",
        "mfy", "tar", "yuli", "yali", "dam", "tashkent", "tashkent",
    ]

    static func tokens(_ text: String) -> [String] {
        fold(text).split(separator: " ").map(String.init)
            .filter { !$0.isEmpty && !noise.contains($0) }
    }

    /// Найти по строке «улица номер».
    ///
    /// Номер отделяем сами и по последнему слову: человек пишет «Навои 12», а
    /// не выбирает поля. Слово считается номером, если начинается с цифры, —
    /// «12», «12/1», «12а» подходят, «Навои» нет.
    func search(_ query: String, near: CLLocationCoordinate2D?,
                limit: Int = 12) -> [Address] {
        let folded = Self.fold(query)
        guard folded.count >= 2 else { return [] }
        var words = folded.split(separator: " ").map(String.init)
        var house: String?
        if let last = words.last, last.first?.isNumber == true, words.count > 1 {
            house = last
            words.removeLast()
        }
        let want = words.filter { !Self.noise.contains($0) }
        guard !want.isEmpty else { return [] }

        var found = addresses.filter { address in
            // Каждое слово запроса обязано начать какое-нибудь слово улицы.
            // Не подстрока целиком: человек пишет «Шота Руставели», а в OSM
            // это «Shota Rustaveli 1-berk ko'chasi» — порядок и лишние слова
            // не должны решать.
            let street = Self.tokens(address.street)
            guard want.allSatisfy({ word in
                street.contains { $0.hasPrefix(word) }
            }) else { return false }
            guard let house else { return true }
            return Self.fold(address.house).hasPrefix(house)
        }
        // Точное совпадение номера — выше похожего: «12» до «12/1».
        if let house {
            found.sort { left, right in
                let leftExact = Self.fold(left.house) == house
                let rightExact = Self.fold(right.house) == house
                if leftExact != rightExact { return leftExact }
                return false
            }
        }
        // Ближнее — выше дальнего. Одинаковых адресов в городе много (улица
        // «Мустакиллик» есть в каждом районе), и без этого первым покажется
        // случайный.
        if let near {
            let origin = CLLocation(latitude: near.latitude, longitude: near.longitude)
            found.sort { left, right in
                let leftExact = house.map { Self.fold(left.house) == $0 } ?? false
                let rightExact = house.map { Self.fold(right.house) == $0 } ?? false
                if leftExact != rightExact { return leftExact }
                return origin.distance(from: CLLocation(latitude: left.point.latitude,
                                                        longitude: left.point.longitude))
                    < origin.distance(from: CLLocation(latitude: right.point.latitude,
                                                       longitude: right.point.longitude))
            }
        }
        return Array(found.prefix(limit))
    }
}
