//
//  SearchIndex.swift
//  RadarMap
//
//  Свой поиск по улицам и местам клетки — «как Elasticsearch», но на телефоне
//  и без сети (40G).
//
//  Жалоба владельца: «метро хамза» не находило ничего. Станция давно
//  называется «Новза», а прежний поиск знал одно имя на запись, требовал
//  каждое слово началом слова имени и ничего не знал о метро. Здесь:
//
//  — все имена записи: нынешнее, другие языки и `alt_name` (поля `a`), старые
//    (`o`) — найденное по старому имени подписывается «бывш. Хамза»;
//  — приведение `fold`: регистр, кириллица ↔ узбекская латиница ↔ русская
//    транслитерация, ё/е, все апострофы, «оʻ»/«ў», «гʻ»/«ғ», ҳ/х/h, қ/q/к;
//  — слова и начала слов, русское окончание («Амира» — «Amir»), нечёткое
//    совпадение (триграммы + Дамерау–Левенштейн, порог по длине слова);
//  — слова вида («метро», «bekati», «азс», «махалля») — подсказка, а не
//    часть имени; слова типа улицы («улица», «ko'chasi», «пр.») не обязательны;
//  — ранжирование: точное > начало > старое имя > нечёткое, затем вид,
//    затем расстояние от машины.
//
//  Индекс строится один раз на клетку (`make`, @concurrent), запрос —
//  миллисекунды на файле Ташкента (бюджет — PerformanceBudgetTests).
//  Чистая логика — SearchIndexTests.
//

import CoreLocation
import Foundation

nonisolated struct SearchIndex: Sendable {

    /// Насколько хорошо совпало. Порядок — порядок выдачи.
    enum Tier: Int, Sendable, Comparable {
        case exact, prefix, oldName, fuzzy
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Ответ экрану поиска: две секции, как раньше, но уже упорядоченные.
    struct Answer: Sendable {
        var addresses: [Address] = []
        var venues: [Venue] = []
        /// id строки (Address.id / Venue.id) → старое имя, по которому она
        /// нашлась: подпись «бывш. Хамза».
        var formerNames: [String: String] = [:]
        /// Лучший ответ — место (метро, махалля, заведение), а не улица:
        /// секцию мест показать первой.
        var venuesFirst = true

        static let empty = Answer()
    }

    // MARK: - Данные индекса

    private let book: AddressBook?
    private let venueBook: VenueBook?
    private let streetCount: Int

    /// Одно имя одной записи. Документ — улица (`doc < streetCount`) или
    /// заведение (`doc - streetCount`).
    private struct Name: Sendable {
        let doc: Int32
        let old: Bool
        /// Основное имя записи, а не другое из `a`: при равном совпадении
        /// улица, которая так и называется, выше той, у чьего куска в OSM
        /// это имя записано вторым («Botkin ko'chasi» с int_name «Mirzo
        /// Ulugbek Avenue»).
        let primary: Bool
        /// Значимых слов в имени (без слов типа улицы): «точное» — когда
        /// запрос покрыл их все.
        let core: Int
        let text: String
    }

    private let names: [Name]
    /// Уникальные приведённые слова — байтами (ASCII после fold).
    private let tokens: [[UInt8]]
    private let tokenIDs: [String: Int32]
    /// Слово → имена, где оно есть.
    private let postings: [[Int32]]
    /// Слово — тип улицы («kuchasi», «ulitsa»): началом или нечётко им не совпадаем.
    private let streetToken: [Bool]
    /// id слов по алфавиту (байтами) — для поиска по началу слова.
    private let sortedTokens: [Int32]
    /// Триграмма (с меткой начала слова) → слова — кандидаты нечёткого.
    private let trigrams: [UInt32: [Int32]]
    /// Номера домов (houseKey, байтами) по алфавиту и дома с каждым: «ka 1»
    /// берёт дом 1 сразу у всех подходящих улиц, не перебирая их дома.
    private let houseKeys: [[UInt8]]
    private let housesByKey: [[Int32]]
    /// Дом (индекс в `addresses`) → его улица.
    private let houseStreet: [Int32]

    // MARK: - Сборка

    /// Индекс клетки — off-main: десятки тысяч слов.
    @concurrent static func make(book: AddressBook?, venues: VenueBook?) async -> SearchIndex {
        SearchIndex(book: book, venues: venues)
    }

    init(book: AddressBook?, venues: VenueBook?) {
        self.book = book
        self.venueBook = venues
        let streets = book?.streets ?? []
        streetCount = streets.count

        var names: [Name] = []
        var tokens: [[UInt8]] = []
        var tokenIDs: [String: Int32] = [:]
        var postings: [[Int32]] = []

        func add(_ text: String, doc: Int, old: Bool, primary: Bool = false) {
            let variants = Self.variants(text)
            guard let main = variants.first, !main.isEmpty else { return }
            let id = Int32(names.count)
            let core = Set(main.filter { !Self.streetWords.contains($0) }).count
            names.append(Name(doc: Int32(doc), old: old, primary: primary, core: max(core, 1), text: text))
            var seen = Set<Int32>()
            for word in variants.joined() {
                let token: Int32
                if let known = tokenIDs[word] {
                    token = known
                } else {
                    token = Int32(tokens.count)
                    tokenIDs[word] = token
                    tokens.append(Array(word.utf8))
                    postings.append([])
                }
                if seen.insert(token).inserted { postings[Int(token)].append(id) }
            }
        }

        for (index, street) in streets.enumerated() {
            add(street.name, doc: index, old: false, primary: true)
            for alias in street.aliases { add(alias, doc: index, old: false) }
            for old in street.oldNames { add(old, doc: index, old: true) }
        }
        for (index, venue) in (venues?.venues ?? []).enumerated() where !venue.name.isEmpty {
            let doc = streets.count + index
            add(venue.name, doc: doc, old: false, primary: true)
            for alias in venue.aliases { add(alias, doc: doc, old: false) }
            for old in venue.oldNames { add(old, doc: doc, old: true) }
        }

        var trigrams: [UInt32: [Int32]] = [:]
        for (id, bytes) in tokens.enumerated() where bytes.count >= 3 {
            var seen = Set<UInt32>()
            for gram in Self.trigrams(of: bytes) where seen.insert(gram).inserted {
                trigrams[gram, default: []].append(Int32(id))
            }
        }

        var byKey: [String: [Int32]] = [:]
        var houseStreet = [Int32](repeating: 0, count: book?.addresses.count ?? 0)
        for (index, street) in streets.enumerated() {
            for (offset, key) in street.houseKeys.enumerated() {
                let address = street.houses.lowerBound + offset
                houseStreet[address] = Int32(index)
                byKey[key, default: []].append(Int32(address))
            }
        }
        let keyed = byKey.map { (Array($0.key.utf8), $0.value) }.sorted { Self.less($0.0, $1.0) }
        self.houseKeys = keyed.map(\.0)
        self.housesByKey = keyed.map(\.1)
        self.houseStreet = houseStreet

        self.names = names
        self.tokens = tokens
        self.tokenIDs = tokenIDs
        self.streetToken = tokens.map { Self.streetWords.contains(String(decoding: $0, as: UTF8.self)) }
        self.postings = postings
        self.sortedTokens = (0..<Int32(tokens.count)).sorted {
            Self.less(tokens[Int($0)], tokens[Int($1)])
        }
        self.trigrams = trigrams
    }

    // MARK: - Приведение

    /// Приведение имени и запроса к одной «слабой латинице» — `AddressBook.fold`
    /// плюс то, чего ему не хватало для поиска: «о'»/«г'» кириллицей с
    /// апострофом (так пишут без ў/ғ на клавиатуре), «дж»/«dj» = «j»
    /// («Алимджан» — «Olimjon»), «kh» = «h» («Khamza» — «Хамза»).
    static func fold(_ text: String, uzbekU: Bool = true) -> String {
        var prepared = ""
        prepared.reserveCapacity(text.count)
        var previous: Character?
        for character in text.lowercased() {
            if apostrophes.contains(character), let last = previous {
                if last == "о" { prepared.removeLast(); prepared.append("ў"); previous = nil; continue }
                if last == "г" { prepared.removeLast(); prepared.append("ғ"); previous = nil; continue }
            }
            prepared.append(character)
            previous = character
        }
        var folded = AddressBook.fold(prepared, uzbekU: uzbekU)
        if folded.contains("dj") { folded = folded.replacingOccurrences(of: "dj", with: "j") }
        if folded.contains("kh") { folded = folded.replacingOccurrences(of: "kh", with: "h") }
        return folded
    }

    private static let apostrophes: Set<Character> = ["'", "\u{2018}", "\u{2019}", "\u{02BB}",
                                                      "\u{02BC}", "`", "\u{00B4}", "\u{02B9}"]

    static func words(_ text: String, uzbekU: Bool = true) -> [String] {
        fold(text, uzbekU: uzbekU).split(separator: " ").map(String.init)
    }

    /// Все виды слов имени: «оʻ» как «у» и как «о» («Kokcha» без апострофа),
    /// и «ё» как «е» — русский пишет «Бунедкор» без точек.
    private static func variants(_ text: String) -> [[String]] {
        var out = [words(text)]
        let plainO = words(text, uzbekU: false)
        if plainO != out[0] { out.append(plainO) }
        if text.contains("ё") || text.contains("Ё") {
            let plainE = words(text.replacingOccurrences(of: "ё", with: "е")
                .replacingOccurrences(of: "Ё", with: "Е"))
            if !out.contains(plainE) { out.append(plainE) }
        }
        return out
    }

    // MARK: - Словари запроса

    /// Слова типа улицы: не обязательны и не значимы («улица Навои» находит
    /// «Alisher Navoiy ko'chasi»), но говорят «ищу улицу».
    static let streetWords: Set<String> = AddressBook.noise
        .subtracting(softWords)
        .union(["ulitsasi", "avenue", "prospekt", "prospekti", "shassesi", "berk", "atish",
                "tor", "kuchasi", "proezd"].map { fold($0) })

    /// Слова, которые обычно ничего не сужают («Ташкент», «шахри») — но если
    /// кроме них в запросе нет ничего, ищем по ним: «Тошкент шахри» — это
    /// сам город.
    static let softWords: Set<String> = Set(["ташкент", "toshkent", "tashkent", "dam", "uy"]
        .map { fold($0) })

    /// Слово вида → вид («метро» → .metro). Только целые слова: начало слова
    /// решает `VenueBook.kind` для запроса из одного слова, как раньше.
    private static let kindWords: [String: Venue.Kind] = {
        var out: [String: Venue.Kind] = [:]
        for (kind, words) in VenueBook.foldedKindWords {
            for word in words where out[word] == nil { out[word] = kind }
        }
        return out
    }()

    // MARK: - Запрос

    /// Слово запроса, разобранное: обязательное, вид, тип улицы или мягкое.
    private struct Query {
        var required: [String] = []
        var optional: [String] = []
        var kinds: Set<Venue.Kind> = []
        var wantsStreet = false
        var house: String?
        /// Последнее слово ещё набирается — ищем и по его началу нечётко.
        var typing = true
        /// В запросе инициал с точкой («K.G‘ofurov»): однобуквенное слово
        /// ищется и началом слова, как у старого поиска.
        var initials = false
    }

    /// `splitHouse: false` — число остаётся словом имени: «Юнусабад 11» для
    /// мест — это квартал «Юнусабад-11», а не дом 11.
    private static func parse(_ text: String, splitHouse: Bool = true) -> Query {
        var query = Query()
        let (streetPart, house) = splitHouse ? AddressBook.splitHouse(text) : (text, nil)
        query.house = house
        query.typing = house == nil && !(text.last?.isWhitespace ?? true)
        query.initials = text.range(of: #"(^|[\s.])\p{L}\."#, options: .regularExpression) != nil
        var soft: [String] = []
        for word in words(streetPart) {
            if let kind = kindWords[word] {
                query.kinds.insert(kind)
                query.optional.append(word)
            } else if streetWords.contains(word) {
                query.wantsStreet = true
                query.optional.append(word)
            } else if softWords.contains(word) {
                soft.append(word)
            } else {
                query.required.append(word)
            }
        }
        if query.required.isEmpty {
            query.required = soft
        } else {
            query.optional += soft
        }
        return query
    }

    /// Найти улицы, дома и места по строке, как её набрали.
    func search(_ text: String, near: CLLocationCoordinate2D?,
                streetLimit: Int = 12, venueLimit: Int = 8) -> Answer {
        guard Self.fold(text).count >= 2 else { return .empty }
        var answer = Answer()

        // Запрос — слово вида целиком («азс», «метро»): ближайшие этого вида,
        // как и раньше; улицы при этом ищутся по имени своим чередом.
        if let kind = VenueBook.kind(for: text), let venueBook {
            answer.venues = venueBook.nearest(kind, to: near, limit: venueLimit)
        }

        let query = Self.parse(text)
        // Места — с числом как словом имени: номер дома бывает только у улицы.
        // Инициал с точкой («K.G‘») — тоже только улицы: «k» и «g» началом
        // слова — это полгорода мест, и они вставали первыми.
        var placeQuery = query.house == nil ? query : Self.parse(text, splitHouse: false)
        placeQuery.initials = false
        guard !query.required.isEmpty || !placeQuery.required.isEmpty else {
            answer.venuesFirst = true
            return answer
        }
        let streetDocs = candidates(query)
        let placeDocs = query.house == nil && !query.initials ? streetDocs : candidates(placeQuery)

        var streets: [(Int, Candidate)] = []
        var venues: [(Int, Candidate)] = []
        for (doc, candidate) in streetDocs where Int(doc) < streetCount {
            streets.append((Int(doc), candidate))
        }
        for (doc, candidate) in placeDocs where Int(doc) >= streetCount {
            venues.append((Int(doc) - streetCount, candidate))
        }
        // Есть хоть один не нечёткий ответ — нечёткие не показываем: «лукойл»
        // нашёл АЗС, и девять улиц «Suhayl ko'chasi» под ней — шум, который
        // ещё и сдвигает ответы Apple вниз.
        let precise = !answer.venues.isEmpty
            || streets.contains { $0.1.tier != .fuzzy } || venues.contains { $0.1.tier != .fuzzy }
        if precise {
            streets.removeAll { $0.1.tier == .fuzzy }
            venues.removeAll { $0.1.tier == .fuzzy }
        }
        return finish(answer, streets: streets, venues: venues, query: query, near: near,
                      streetLimit: streetLimit, venueLimit: venueLimit)
    }

    /// Документы, где есть все обязательные слова запроса, с лучшим совпадением.
    private func candidates(_ query: Query) -> [Int32: Candidate] {
        let found = intersect(query)
        guard found.isEmpty else { return found }
        // «амир темур шо», «буюк ипак йу» — начало слова типа улицы посреди
        // набора («shoh», «yo'li»): само оно с «shah…» не совпадает (так «ka 1»
        // не значит «все улицы»), и пустой ответ мигал на каждой второй букве.
        // Такое слово необязательно — кроме единственного слова запроса и
        // одной-двух букв перед номером дома.
        var relaxed = query
        relaxed.required = query.required.enumerated().filter { position, word in
            let isLast = position == query.required.count - 1
            let shortBeforeHouse = query.house != nil && word.count <= 2
            return !(isLast && query.required.count > 1 && !shortBeforeHouse && Self.isStreetWordStart(word))
        }.map(\.element)
        guard relaxed.required.count < query.required.count else { return [:] }
        relaxed.optional.append(query.required[query.required.count - 1])
        relaxed.wantsStreet = true
        return intersect(relaxed)
    }

    /// Слово — начало слова типа улицы («sha» — «shah», «yu» — «yuli»).
    private static func isStreetWordStart(_ word: String) -> Bool {
        streetWords.contains { $0.hasPrefix(word) }
    }

    private func intersect(_ query: Query) -> [Int32: Candidate] {
        guard !query.required.isEmpty else { return [:] }
        // Совпадения каждого обязательного слова: имя → качество (0 — слово
        // целиком, 1 — начало или окончание, 2+ — нечёткое с d правками).
        var perWord: [[Int32: UInt8]] = []
        for (position, word) in query.required.enumerated() {
            let last = position == query.required.count - 1 && query.typing
            let found = matches(word, typing: last, initial: query.initials)
            if found.isEmpty { return [:] }
            perWord.append(found)
        }
        // Имена, где есть необязательные слова запроса: множества — один раз
        // на запрос, а не проверка списка на каждое имя-кандидат.
        let optionalNames = query.optional.map { word in
            prefixTokens(word).reduce(into: Set<Int32>()) { set, token in set.formUnion(postings[Int(token)]) }
        }

        // Пересечение — от самого узкого слова.
        let order = perWord.indices.sorted { perWord[$0].count < perWord[$1].count }
        var best: [Int32: Candidate] = [:]
        for (nameID, firstQuality) in perWord[order[0]] {
            var worst = firstQuality
            var fuzzy = firstQuality >= 2
            var all = true
            for index in order.dropFirst() {
                guard let quality = perWord[index][nameID] else { all = false; break }
                worst = max(worst, quality)
                fuzzy = fuzzy || quality >= 2
            }
            guard all else { continue }
            let name = names[Int(nameID)]
            let tier: Tier
            if fuzzy { tier = .fuzzy }
            else if name.old { tier = .oldName }
            else if worst == 0, query.required.count >= name.core { tier = .exact }
            else { tier = .prefix }
            let extra = optionalNames.reduce(0) { $0 + ($1.contains(nameID) ? 1 : 0) }
            // «бывш.» — только когда нашлось именно по старому имени, а не
            // нечётко рядом с ним: иначе подпись выдаёт догадку за объяснение.
            let candidate = Candidate(tier: tier, extra: extra, primary: name.primary,
                                      former: tier == .oldName ? name.text : nil)
            if let current = best[name.doc], !candidate.better(than: current) { continue }
            best[name.doc] = candidate
        }
        return best
    }

    private struct Candidate {
        let tier: Tier
        /// Сколько необязательных слов запроса («метро», «улица») тоже есть в имени.
        let extra: Int
        let primary: Bool
        let former: String?

        func better(than other: Candidate) -> Bool {
            if tier != other.tier { return tier < other.tier }
            if extra != other.extra { return extra > other.extra }
            return primary && !other.primary
        }
    }

    // MARK: - Выдача

    private func finish(_ start: Answer, streets: [(Int, Candidate)], venues: [(Int, Candidate)],
                        query: Query, near: CLLocationCoordinate2D?,
                        streetLimit: Int, venueLimit: Int) -> Answer {
        var answer = start
        // Подсказка вида: 0 — запись того вида, о котором просили («метро»,
        // «улица»), 1 — другого. Без подсказки все равны.
        func venuePenalty(_ kind: Venue.Kind) -> Int {
            if !query.kinds.isEmpty { return query.kinds.contains(kind) ? 0 : 1 }
            return query.wantsStreet ? 1 : 0
        }
        let streetPenalty = query.wantsStreet ? 0 : (query.kinds.isEmpty ? 0 : 1)
        var bestVenue: (Int, Int)?

        // Места.
        if let venueBook, !venues.isEmpty {
            let rows = venues.map { index, candidate in
                let venue = venueBook.venues[index]
                return VenueRow(venue: index, hint: venuePenalty(venue.kind), candidate: candidate,
                                rank: Self.kindRank(venue.kind),
                                distance: near.map { Self.distance($0, venue.point) } ?? 0)
            }
            var ranked = Ranked(rows) { left, right in
                if left.hint != right.hint { return left.hint < right.hint }
                if left.candidate.tier != right.candidate.tier { return left.candidate.tier < right.candidate.tier }
                if left.candidate.extra != right.candidate.extra { return left.candidate.extra > right.candidate.extra }
                if left.candidate.primary != right.candidate.primary { return left.candidate.primary }
                if left.rank != right.rank { return left.rank < right.rank }
                if left.distance != right.distance { return left.distance < right.distance }
                let leftName = venueBook.venues[left.venue].name, rightName = venueBook.venues[right.venue].name
                if leftName != rightName { return leftName < rightName }
                return left.venue < right.venue
            }
            var seen = Set(answer.venues.map(\.id))
            while answer.venues.count < venueLimit || bestVenue == nil, let row = ranked.next() {
                if bestVenue == nil { bestVenue = (row.hint, row.candidate.tier.rawValue) }
                guard answer.venues.count < venueLimit else { break }
                let venue = venueBook.venues[row.venue]
                guard seen.insert(venue.id).inserted else { continue }
                answer.venues.append(venue)
                if let former = row.candidate.former { answer.formerNames[venue.id] = former }
            }
        }

        // Улицы и дома.
        var bestStreet: (Int, Int)?
        if let book, !streets.isEmpty {
            let streetHint = streetPenalty
            if let house = query.house {
                // Сначала точный номер (он всегда выше начала номера) — из
                // индекса номеров, без перебора домов каждой улицы; начало
                // номера («1» — «12», «1а») — только если точных не хватило.
                // Address, его id и подпись «бывш.» — только для строк ответа
                // (ревью 03.11: строка на каждый из ~30 тысяч домов — 170 мс).
                var position = [Int32](repeating: -1, count: streetCount)
                for (slot, street) in streets.enumerated() { position[street.0] = Int32(slot) }
                let key = Array(house.utf8)
                let keys = houseKeyRange(key)
                let exactKey = keys.first.flatMap { houseKeys[$0] == key ? $0 : nil }
                func row(_ address: Int32) -> HouseRow? {
                    let slot = position[Int(houseStreet[Int(address)])]
                    guard slot >= 0 else { return nil }
                    return HouseRow(address: Int(address), candidate: streets[Int(slot)].1,
                                    distance: near.map { Self.distance($0, book.addresses[Int(address)].point) } ?? 0)
                }
                func show(_ rows: [HouseRow]) {
                    var ranked = Ranked(rows) { left, right in
                        if left.candidate.tier != right.candidate.tier { return left.candidate.tier < right.candidate.tier }
                        if left.distance != right.distance { return left.distance < right.distance }
                        return left.address < right.address
                    }
                    while answer.addresses.count < streetLimit || bestStreet == nil, let row = ranked.next() {
                        if bestStreet == nil { bestStreet = (streetHint, row.candidate.tier.rawValue) }
                        guard answer.addresses.count < streetLimit else { break }
                        let address = book.addresses[row.address]
                        // Один адрес — одна строка (точка и контур дома в OSM).
                        let twin = answer.addresses.contains { other in
                            other.street == address.street && other.house == address.house
                                && Self.distance(other.point, address.point) < AppConfig.addressDuplicateMeters
                        }
                        if twin { continue }
                        answer.addresses.append(address)
                        if let former = row.candidate.former { answer.formerNames[address.id] = former }
                    }
                }
                if let exactKey { show(housesByKey[exactKey].compactMap(row)) }
                if answer.addresses.count < streetLimit {
                    let longer = keys.filter { $0 != exactKey }
                    let indexed = longer.reduce(0) { $0 + housesByKey[$1].count }
                    let scanned = streets.reduce(0) { $0 + book.streets[$1.0].houses.count }
                    var rows: [HouseRow] = []
                    // Дешевле из двух: дома с таким началом номера по всему
                    // файлу или все дома подошедших улиц.
                    if indexed <= scanned {
                        for slot in longer { rows += housesByKey[slot].compactMap(row) }
                    } else {
                        for (index, candidate) in streets {
                            let street = book.streets[index]
                            for (offset, houseKey) in street.houseKeys.enumerated()
                            where houseKey.utf8.count > key.count && houseKey.utf8.starts(with: key) {
                                let address = street.houses.lowerBound + offset
                                rows.append(HouseRow(address: address, candidate: candidate,
                                                     distance: near.map { Self.distance($0, book.addresses[address].point) } ?? 0))
                            }
                        }
                    }
                    show(rows)
                }
            } else {
                var rows: [StreetRow] = []
                rows.reserveCapacity(streets.count)
                for (index, candidate) in streets {
                    let street = book.streets[index]
                    guard !street.houses.isEmpty else { continue }
                    var pick = street.houses.lowerBound + street.houses.count / 2
                    var pickDistance = 0.0
                    if let near {
                        pickDistance = .infinity
                        for house in street.houses {
                            let distance = Self.distance(near, book.addresses[house].point)
                            if distance < pickDistance { pick = house; pickDistance = distance }
                        }
                    }
                    rows.append(StreetRow(street: index, pick: pick, candidate: candidate, distance: pickDistance))
                }
                var ranked = Ranked(rows) { left, right in
                    if left.candidate.tier != right.candidate.tier { return left.candidate.tier < right.candidate.tier }
                    if left.candidate.extra != right.candidate.extra { return left.candidate.extra > right.candidate.extra }
                    if left.candidate.primary != right.candidate.primary { return left.candidate.primary }
                    if left.distance != right.distance { return left.distance < right.distance }
                    return left.street < right.street
                }
                while answer.addresses.count < streetLimit || bestStreet == nil, let row = ranked.next() {
                    if bestStreet == nil { bestStreet = (streetHint, row.candidate.tier.rawValue) }
                    guard answer.addresses.count < streetLimit else { break }
                    let address = Address(street: book.streets[row.street].name, house: "",
                                          point: book.addresses[row.pick].point)
                    answer.addresses.append(address)
                    if let former = row.candidate.former { answer.formerNames[address.id] = former }
                }
            }
        }

        switch (bestVenue, bestStreet) {
        case let (venue?, street?): answer.venuesFirst = venue <= street
        case (nil, _?): answer.venuesFirst = !answer.venues.isEmpty && answer.addresses.isEmpty
        default: answer.venuesFirst = true
        }
        return answer
    }

    private struct VenueRow {
        let venue: Int
        let hint: Int
        let candidate: Candidate
        let rank: Int
        let distance: Double
    }

    private struct StreetRow {
        let street: Int
        let pick: Int
        let candidate: Candidate
        let distance: Double
    }

    private struct HouseRow {
        let address: Int
        let candidate: Candidate
        let distance: Double
    }

    /// Строки по порядку `less` без полной сортировки: в ответ идут 8–12
    /// из тысяч, и сортировка всех была главной ценой запроса. Берёт первые
    /// `take`, при нехватке (дубли пропущены) — вдвое больше. `less` —
    /// строгий полный порядок, иначе добор сдвинет уже выданные строки.
    private struct Ranked<Row>: IteratorProtocol {
        private let rows: [Row]
        private let less: (Row, Row) -> Bool
        private var take: Int
        private var top: [Row] = []
        private var position = 0
        private var started = false

        init(_ rows: [Row], take: Int = 16, by less: @escaping (Row, Row) -> Bool) {
            self.rows = rows
            self.less = less
            self.take = take
        }

        mutating func next() -> Row? {
            if position == top.count {
                if started, top.count == rows.count { return nil }
                if started { take *= 2 }
                started = true
                top = SearchIndex.leading(rows, take, by: less)
                guard position < top.count else { return nil }
            }
            defer { position += 1 }
            return top[position]
        }
    }

    /// Первые `count` строк по порядку `less`, отсортированные.
    private static func leading<Row>(_ rows: [Row], _ count: Int, by less: (Row, Row) -> Bool) -> [Row] {
        if count >= rows.count { return rows.sorted(by: less) }
        var top: [Row] = []
        top.reserveCapacity(count + 1)
        for row in rows {
            if top.count == count, let last = top.last, !less(row, last) { continue }
            var low = 0, high = top.count
            while low < high {
                let mid = (low + high) / 2
                if less(top[mid], row) { low = mid + 1 } else { high = mid }
            }
            top.insert(row, at: low)
            if top.count > count { top.removeLast() }
        }
        return top
    }

    /// Номера домов, начинающиеся с `prefix` (включая равный), — индексы в `houseKeys`.
    private func houseKeyRange(_ prefix: [UInt8]) -> Range<Int> {
        var low = 0, high = houseKeys.count
        while low < high {
            let mid = (low + high) / 2
            if Self.less(houseKeys[mid], prefix) { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < houseKeys.count, houseKeys[end].starts(with: prefix) { end += 1 }
        return low..<end
    }

    /// При равном совпадении: станция и район выше кафе с тем же словом в
    /// имени — «Чорсу» это прежде всего метро и место, а не лаваш «Чорсу 2».
    private static func kindRank(_ kind: Venue.Kind) -> Int {
        switch kind {
        case .metro: return 0
        case .place: return 1
        default:     return 2
        }
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        GeoMath.fastDistance(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    // MARK: - Совпадения слова

    /// Имена, где есть слово запроса: целиком (0), началом или без русского
    /// окончания (1), нечётко (2 + число правок).
    private func matches(_ word: String, typing: Bool, initial: Bool = false) -> [Int32: UInt8] {
        var out: [Int32: UInt8] = [:]
        func mark(_ token: Int32, _ quality: UInt8) {
            // Обязательное слово не бывает словом типа улицы: «ka» — не
            // «ko'chasi», иначе «ka 1» — это все улицы города (ревью 03.11).
            if quality > 0, streetToken[Int(token)] { return }
            for name in postings[Int(token)] {
                if let known = out[name], known <= quality { continue }
                out[name] = quality
            }
        }
        let bytes = Array(word.utf8)
        if let exact = tokenIDs[word] { mark(exact, 0) }
        // Начало слова — с двух букв: одна буква — это полгорода. Кроме
        // инициала с точкой («K.G‘…») и числа.
        if bytes.count >= 2 || word.first?.isNumber == true || initial {
            for token in prefixRange(bytes) where tokens[Int(token)].count != bytes.count {
                mark(token, 1)
            }
        }
        // «Амира», «Навои», «Улугбека» — русский падеж: слово без окончания.
        if bytes.count >= 5, let last = bytes.last, Self.endings.contains(last) {
            let stem = String(decoding: bytes.dropLast(), as: UTF8.self)
            if let token = tokenIDs[stem] { mark(token, 1) }
        }
        let edits = Self.maxEdits(bytes.count)
        if edits > 0 {
            for token in fuzzyCandidates(bytes, edits: edits, typing: typing) {
                let target = tokens[Int(token)]
                var distance = Self.osa(bytes, target, limit: edits)
                if typing, distance > 0 {
                    distance = min(distance, Self.prefixOSA(bytes, target, limit: edits))
                }
                if distance > 0, distance <= edits { mark(token, UInt8(1 + distance)) }
            }
        }
        return out
    }

    /// Окончания русского падежа после fold: а, я (ya → a), у, е. Без «и»:
    /// у «Навои» она своя, и «Навои 12» находило «Ново-Ульяновскую».
    private static let endings: Set<UInt8> = [UInt8(ascii: "a"), UInt8(ascii: "u"), UInt8(ascii: "e")]

    /// Порог правок по длине слова: до трёх букв — только точно (иначе «уч»
    /// находит пол-алфавита), 4–5 — одна правка, длиннее — две.
    static func maxEdits(_ length: Int) -> Int {
        switch length {
        case ..<4: return 0
        case 4...5: return 1
        default: return 2
        }
    }

    private func prefixTokens(_ word: String) -> Set<Int32> {
        var out = Set(prefixRange(Array(word.utf8)))
        if let exact = tokenIDs[word] { out.insert(exact) }
        return out
    }

    /// Слова, начинающиеся с `prefix` (включая равное), — бинарный поиск по алфавиту.
    private func prefixRange(_ prefix: [UInt8]) -> ArraySlice<Int32> {
        var low = 0, high = sortedTokens.count
        while low < high {
            let mid = (low + high) / 2
            if Self.less(tokens[Int(sortedTokens[mid])], prefix) { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < sortedTokens.count, tokens[Int(sortedTokens[end])].starts(with: prefix) { end += 1 }
        return sortedTokens[low..<end]
    }

    /// Кандидаты нечёткого: общие триграммы и подходящая длина.
    private func fuzzyCandidates(_ word: [UInt8], edits: Int, typing: Bool) -> [Int32] {
        let grams = Set(Self.trigrams(of: word))
        guard !grams.isEmpty else { return [] }
        var counts: [Int32: Int] = [:]
        for gram in grams {
            for token in trigrams[gram] ?? [] { counts[token, default: 0] += 1 }
        }
        // Каждая правка рушит не больше трёх триграмм.
        let need = max(1, grams.count - 3 * edits)
        return counts.compactMap { token, shared in
            guard shared >= need else { return nil }
            let length = tokens[Int(token)].count
            if typing { return length + edits >= word.count ? token : nil }
            return abs(length - word.count) <= edits ? token : nil
        }
    }

    // MARK: - Строки

    private static func less(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.lexicographicallyPrecedes(b)
    }

    /// Триграммы слова с меткой начала (`\u{1}`): начало слова весомее
    /// середины — «hamza» и «hamid» делят «^ha», а «amza» нет.
    static func trigrams(of word: [UInt8]) -> [UInt32] {
        let padded = [UInt8(1)] + word
        guard padded.count >= 3 else { return [] }
        return (0...(padded.count - 3)).map { index in
            UInt32(padded[index]) << 16 | UInt32(padded[index + 1]) << 8 | UInt32(padded[index + 2])
        }
    }

    /// Расстояние Дамерау–Левенштейна (оптимальное выравнивание строк):
    /// вставка, удаление, замена и перестановка соседних. Больше `limit` —
    /// `limit + 1` (дальше считать незачем).
    static func osa(_ a: [UInt8], _ b: [UInt8], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        return table(a, b, limit: limit).full
    }

    /// То же, но до начала `b` не короче `a`: «hamzq» до «hamza…» — одна
    /// правка. Слово запроса, которое ещё набирают. Короче нельзя: иначе
    /// «novza» находила бы «nava…» (Навои), выбросив последнюю букву.
    static func prefixOSA(_ a: [UInt8], _ b: [UInt8], limit: Int) -> Int {
        table(a, b, limit: limit).prefix
    }

    private static func table(_ a: [UInt8], _ b: [UInt8], limit: Int) -> (full: Int, prefix: Int) {
        let n = a.count, m = b.count
        if n == 0 { return (m, 0) }
        if m == 0 { return (n, n) }
        var previous2 = [Int](repeating: 0, count: m + 1)
        var previous = Array(0...m)
        var current = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            current[0] = i
            var rowMin = current[0]
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previous2[j - 2] + 1)
                }
                current[j] = value
                rowMin = min(rowMin, value)
            }
            if rowMin > limit { return (limit + 1, limit + 1) }
            swap(&previous2, &previous)
            swap(&previous, &current)
        }
        // `previous` — последняя строка; начало `b` не короче `a`.
        let tail = n <= m ? previous[n...m].min() ?? limit + 1 : previous[m]
        return (min(previous[m], limit + 1), min(tail, limit + 1))
    }
}
