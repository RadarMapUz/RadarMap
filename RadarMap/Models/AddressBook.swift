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

nonisolated struct Address: Sendable, Equatable, Identifiable {
    let street: String
    let house: String
    let point: CLLocationCoordinate2D

    /// Как показать человеку: «Навои, 12». Без номера — улица целиком.
    var title: String { house.isEmpty ? street : "\(street), \(house)" }

    /// Строка списка: одинаковые адреса бывают в разных районах («Мустакиллик,
    /// 5» есть не один), поэтому одного названия для id мало.
    var id: String {
        String(format: "%@|%.5f|%.5f", title, point.latitude, point.longitude)
    }

    /// Это вся улица, а не дом (ответ на запрос без номера).
    var isStreet: Bool { house.isEmpty }

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

    /// Улица и её дома (подряд в `addresses`). Слова названия сведены ОДИН
    /// раз: раньше каждая буква запроса сводила название заново для каждого
    /// дома — 115 тысяч раз вместо трёх тысяч, на главном потоке.
    struct Street: Sendable {
        let name: String
        let tokens: [String]
        let houses: Range<Int>
        /// Номера в сравнимом виде (houseKey) — по одному на дом.
        let houseKeys: [String]
        /// Другие нынешние имена улицы («Амира Темура проспект» при
        /// «Amir Temur shoh ko'chasi») и старые («Московский проспект») —
        /// поля `a`/`o` клетки, их ищет SearchIndex. Пусто у старых файлов.
        var aliases: [String] = []
        var oldNames: [String] = []
    }

    let streets: [Street]

    /// `names` — имена улиц из файла клетки (`a`/`o`) по основному имени.
    init(addresses: [Address], names: [String: (aliases: [String], old: [String])] = [:]) {
        self.addresses = addresses
        var streets: [Street] = []
        var start = 0
        while start < addresses.count {
            let name = addresses[start].street
            var end = start + 1
            while end < addresses.count, addresses[end].street == name { end += 1 }
            streets.append(Street(name: name, tokens: Self.streetTokens(name), houses: start..<end,
                                  houseKeys: addresses[start..<end].map { Self.houseKey($0.house) },
                                  aliases: names[name]?.aliases ?? [], oldNames: names[name]?.old ?? []))
            start = end
        }
        self.streets = streets
    }

    /// Разобрать файл клетки. nil — файл не наш или битый: ответ «адресов
    /// нет» честнее, чем половина списка.
    static func decode(_ data: Data) -> AddressBook? {
        // Не JSON — тот же ответ «файл не наш» (nil), что и при чужом формате.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streets = root["streets"] as? [[String: Any]]
        else { return nil }

        var out: [Address] = []
        var names: [String: (aliases: [String], old: [String])] = [:]
        for street in streets {
            guard let name = street["n"] as? String,
                  let houses = street["h"] as? [String],
                  let flat = street["p"] as? [NSNumber]
            else { continue }
            // Необязательные имена (40G): нет или не тот тип — просто без них.
            let aliases = street["a"] as? [String] ?? [], old = street["o"] as? [String] ?? []
            if !aliases.isEmpty || !old.isEmpty { names[name] = (aliases, old) }
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
        return AddressBook(addresses: out, names: names)
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
    /// — `oʻ` и `ў` — это русское «у» («Oʻzbekiston» — «Узбекистан»,
    ///   «Koʻkcha» — «Кукча»), а остальные апострофы просто склеивают слово
    ///   («Ulugʻbek» — «Улугбек»). До 10.10.2026 апостроф рвал слово надвое,
    ///   и «Улугбек» не находил «Mirzo Ulugʻbek» вовсе;
    /// — `q`→`k`, `x`→`h`, `w`→`v`, `zh`→`j`: узбекская латиница и русская
    ///   транслитерация расходятся ровно в этих буквах («Мустакиллик» против
    ///   «Mustaqillik»);
    /// — `o`→`a`: систематическое расхождение узбекского и русского написания
    ///   («Chilonzor» против «Чиланзар», «Toshkent» против «Ташкент»).
    ///   Проверено на живом файле: без него «Чиланзар» не находится вовсе, а
    ///   с ним число лишних попаданий не растёт;
    /// — `-iy` на конце слова — `-i`: «Navoiy» — «Навои», «Beruniy» — «Беруни».
    ///
    /// `uzbekU: false` — «oʻ» как «о» без апострофа: так пишет тот, кто
    /// набирает латиницей без апострофа («Kokcha»), и так выглядит слово,
    /// пока апостроф ещё не набран. Название из данных хранится в обоих видах
    /// (streetTokens), запрос — как набран.
    static func fold(_ text: String, uzbekU: Bool = true) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var previous: Character?
        for character in text.lowercased() {
            if apostrophes.contains(character) {
                // «oʻ» — отдельная буква, по-русски «у»; прочие апострофы
                // («gʻ», «ko'cha» с ошибкой) просто исчезают.
                if previous == "o", uzbekU { out.removeLast(); out += "u" }
                previous = nil
                continue
            }
            if let latin = cyrillic[character] {
                out += latin
            } else {
                out.append(character)
            }
            previous = character
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
        return loose.split(separator: " ").map { word in
            word.count > 3 && word.hasSuffix("iy") ? String(word.dropLast()) : String(word)
        }.joined(separator: " ")
    }

    /// Все апострофы, которыми пишут узбекскую латиницу: прямой, типографские,
    /// модификаторы (ʻ — официальный, U+02BB) и обратный штрих с клавиатуры.
    private static let apostrophes: Swift.Set<Character> = ["'", "\u{2018}", "\u{2019}", "\u{02BB}",
                                                            "\u{02BC}", "`", "\u{00B4}", "\u{02B9}"]

    private static let cyrillic: [Character: String] = [
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo",
        "ж": "j", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "h", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sh",
        "ъ": "", "ы": "i", "ь": "", "э": "e", "ю": "yu", "я": "ya",
        "ў": "u", "қ": "k", "ғ": "g", "ҳ": "h", "ә": "a",
    ]

    /// Номер дома в сравнимом виде: «12/1», «12-1», «12 / 1» — одно; буква
    /// корпуса кириллицей и латиницей — одна («12А» и «12a»).
    static func houseKey(_ text: String) -> String {
        var out = ""
        for character in text.lowercased() {
            if character.isNumber { out.append(character) }
            else if character == "/" || character == "-" { out.append("/") }
            else if let latin = cyrillic[character], latin.count == 1 { out += latin }
            else if character.isLetter { out.append(character) }
        }
        return out
    }

    /// Разделить запрос на улицу и номер дома.
    ///
    /// Номер — последний кусок, начинающийся с цифры, вместе с корпусом через
    /// дробь: «Навои 12/1», «Навои 12 а», «Навои, д.12», «Navoiy uy 12».
    /// Разбирается по ИСХОДНОЙ строке: приведение превращало «/» в пробел, и
    /// «12/1» становилось улицей «12» и домом «1».
    static func splitHouse(_ query: String) -> (street: String, house: String?) {
        guard let regex = houseRegex,
              let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
              let streetRange = Range(match.range(at: 1), in: query),
              let houseRange = Range(match.range(at: 2), in: query) else { return (query, nil) }
        let street = String(query[streetRange])
        // Запрос из одних цифр — это улица («1-й проезд»), а не номер.
        guard !tokens(street).isEmpty else { return (query, nil) }
        return (street, houseKey(String(query[houseRange])))
    }

    /// Шаблон «улица + номер» — компилируется один раз, а не на каждую букву
    /// запроса (поиск зовёт splitHouse на каждом нажатии; аудит 11.10).
    // Шаблон — константа, покрытая тестами поиска: ошибки компиляции здесь не бывает.
    private static let houseRegex = try? NSRegularExpression(
        pattern: #"^(.*?)[\s,]+(?:(?:д|дом|uy|d|№)\.?\s*)?(\d+\s*[\p{L}]?(?:\s*[/-]\s*\d+\s*[\p{L}]?)?)\s*$"#,
        options: [.caseInsensitive])

    /// Слова, которые не сужают поиск.
    ///
    /// «улица», «ko'chasi», «street» стоят у половины улиц города и не
    /// отличают ни одну от другой. Выбрасываем их с ОБЕИХ сторон: иначе
    /// «улица Навои» не находит «Alisher Navoiy ko'chasi», потому что слова
    /// «улица» в нём нет.
    static let noise: Swift.Set<String> = [
        "ulitsa", "ul", "kachasi", "kacha", "kuchasi", "kucha", "street", "st",
        "praezd", "pereulak", "per", "shasse", "tupik", "massiv", "mahalla",
        "mfy", "tar", "yuli", "yali", "dam", "tashkent",
        // «Amir Temur shoh ko'chasi» — это «проспект Амира Темура».
        "praspekt", "pr", "shah",
    ]

    static func tokens(_ text: String, uzbekU: Bool = true) -> [String] {
        fold(text, uzbekU: uzbekU).split(separator: " ").map(String.init)
            .filter { !$0.isEmpty && !noise.contains($0) }
    }

    /// Слова названия улицы в обоих видах «oʻ» (см. fold): «Koʻkcha»
    /// находится и по «Кукча», и по «Kokcha».
    static func streetTokens(_ name: String) -> [String] {
        var seen = Swift.Set<String>()
        return (tokens(name) + tokens(name, uzbekU: false)).filter { seen.insert($0).inserted }
    }

    /// Улицы, подходящие под слова запроса (каждое слово начинает какое-нибудь
    /// слово названия; порядок и лишние слова в данных не решают).
    private func matchingStreets(_ want: [String]) -> [Street] {
        streets.filter { street in
            want.allSatisfy { word in street.tokens.contains { $0.hasPrefix(word) } }
        }
    }

    /// Найти дома по строке «улица номер».
    ///
    /// Номер отделяем сами (splitHouse): человек пишет «Навои 12», а не
    /// выбирает поля. Без номера — все дома подходящих улиц.
    func search(_ query: String, near: CLLocationCoordinate2D?,
                limit: Int = 12) -> [Address] {
        guard Self.fold(query).count >= 2 else { return [] }
        let (streetPart, house) = Self.splitHouse(query)
        let want = Self.tokens(streetPart)
        guard !want.isEmpty else { return [] }

        // (адрес, номер совпал точно, расстояние до машины)
        var found: [(address: Address, exact: Bool, distance: Double)] = []
        for street in matchingStreets(want) {
            for (offset, index) in street.houses.enumerated() {
                let key = street.houseKeys[offset]
                if let house, !key.hasPrefix(house) { continue }
                let address = addresses[index]
                let distance = near.map {
                    GeoMath.fastDistance($0.latitude, $0.longitude,
                                         address.point.latitude, address.point.longitude)
                } ?? 0
                found.append((address, house.map { key == $0 } ?? false, distance))
            }
        }
        // Точное совпадение номера — выше похожего («12» до «12/1»); затем
        // ближнее выше дальнего: одинаковых адресов в городе много (улица
        // «Мустакиллик» есть в каждом районе), и без этого первым покажется
        // случайный. Порядок файла — последний ключ, чтобы ответ не прыгал.
        found.sort { left, right in
            if left.exact != right.exact { return left.exact }
            return left.distance < right.distance
        }
        return Self.distinct(found.map(\.address), limit: limit)
    }

    /// Ответ для экрана поиска: с номером — дома, без номера — УЛИЦЫ.
    ///
    /// На «Навои» раньше приходили двенадцать домов одной улицы, а самой
    /// улицы в ответе не было. Улица — одна строка, точка — её дом, ближайший
    /// к машине (без машины — средний): маршрут «на Навои» ведёт туда, где
    /// улица ближе, а не в её случайный конец.
    func lookup(_ query: String, near: CLLocationCoordinate2D?, limit: Int = 12) -> [Address] {
        guard Self.fold(query).count >= 2 else { return [] }
        let (streetPart, house) = Self.splitHouse(query)
        if house != nil { return search(query, near: near, limit: limit) }
        let want = Self.tokens(streetPart)
        guard !want.isEmpty else { return [] }
        var found: [(address: Address, distance: Double)] = []
        for street in matchingStreets(want) where !street.houses.isEmpty {
            var best = street.houses.lowerBound + street.houses.count / 2
            var bestDistance = 0.0
            if let near {
                bestDistance = .infinity
                for index in street.houses {
                    let point = addresses[index].point
                    let distance = GeoMath.fastDistance(near.latitude, near.longitude,
                                                        point.latitude, point.longitude)
                    if distance < bestDistance { best = index; bestDistance = distance }
                }
            }
            found.append((Address(street: street.name, house: "", point: addresses[best].point),
                          bestDistance))
        }
        found.sort { $0.distance < $1.distance }
        return Array(found.prefix(limit).map(\.address))
    }

    /// Ближайший дом к точке — подпись под булавкой «Выбрать на карте».
    ///
    /// Поиск по имени тут не помогает: человек показал место пальцем, и
    /// вопрос обратный — «что здесь». Не ближе `maxMeters` — nil: адрес
    /// соседнего квартала под булавкой хуже честного «Точка на карте», а в
    /// «Моих местах» он остался бы навсегда.
    ///
    /// Перебор, а не индекс: в клетке города ~10–20 тысяч домов — доли
    /// миллисекунды, а вызов бывает раз на остановку карты, не на кадр.
    func nearest(to point: CLLocationCoordinate2D, within maxMeters: Double) -> Address? {
        var best: Address?
        var bestDistance = maxMeters
        for address in addresses {
            let distance = GeoMath.fastDistance(point.latitude, point.longitude,
                                                address.point.latitude, address.point.longitude)
            // Строгое «меньше»: из двух равноудалённых побеждает первый по
            // файлу — подпись не прыгает между соседями от вызова к вызову.
            if distance < bestDistance {
                best = address
                bestDistance = distance
            }
        }
        return best
    }

    /// Один адрес — одна строка. В OSM дом бывает и точкой, и контуром, и
    /// оба приезжают с тем же номером в паре метров: в списке это два
    /// одинаковых ряда (и два одинаковых id у ForEach).
    static func distinct(_ addresses: [Address], limit: Int) -> [Address] {
        var out: [Address] = []
        for address in addresses {
            let twin = out.contains { other in
                other.title == address.title
                    && GeoMath.fastDistance(other.point.latitude, other.point.longitude,
                                            address.point.latitude, address.point.longitude)
                        < AppConfig.addressDuplicateMeters
            }
            if !twin { out.append(address) }
            if out.count >= limit { break }
        }
        return out
    }
}
