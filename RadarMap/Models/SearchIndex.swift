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
    /// id слов по алфавиту (байтами) — для поиска по началу слова.
    private let sortedTokens: [Int32]
    /// Триграмма (с меткой начала слова) → слова — кандидаты нечёткого.
    private let trigrams: [UInt32: [Int32]]

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

        self.names = names
        self.tokens = tokens
        self.tokenIDs = tokenIDs
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
    }

    private static func parse(_ text: String) -> Query {
        var query = Query()
        let (streetPart, house) = AddressBook.splitHouse(text)
        query.house = house
        query.typing = house == nil && !(text.last?.isWhitespace ?? true)
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
        guard !query.required.isEmpty else {
            answer.venuesFirst = true
            return answer
        }

        // Совпадения каждого обязательного слова: имя → качество (0 — слово
        // целиком, 1 — начало или окончание, 2+ — нечёткое с d правками).
        var perWord: [[Int32: UInt8]] = []
        for (position, word) in query.required.enumerated() {
            let last = position == query.required.count - 1 && query.typing
            let found = matches(word, typing: last)
            if found.isEmpty { return finish(answer, streets: [], venues: [], query: query, near: near,
                                             streetLimit: streetLimit, venueLimit: venueLimit) }
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
            let candidate = Candidate(tier: tier, extra: extra, primary: name.primary,
                                      former: name.old ? name.text : nil)
            if let current = best[name.doc], !candidate.better(than: current) { continue }
            best[name.doc] = candidate
        }

        var streets: [(Int, Candidate)] = []
        var venues: [(Int, Candidate)] = []
        for (doc, candidate) in best {
            if Int(doc) < streetCount { streets.append((Int(doc), candidate)) }
            else if query.house == nil { venues.append((Int(doc) - streetCount, candidate)) }
        }
        return finish(answer, streets: streets, venues: venues, query: query, near: near,
                      streetLimit: streetLimit, venueLimit: venueLimit)
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
            let ranked = venues.map { index, candidate in
                let venue = venueBook.venues[index]
                return (venue, candidate, near.map { Self.distance($0, venue.point) } ?? 0)
            }.sorted { left, right in
                let leftHint = venuePenalty(left.0.kind), rightHint = venuePenalty(right.0.kind)
                if leftHint != rightHint { return leftHint < rightHint }
                if left.1.tier != right.1.tier { return left.1.tier < right.1.tier }
                if left.1.extra != right.1.extra { return left.1.extra > right.1.extra }
                if left.1.primary != right.1.primary { return left.1.primary }
                let leftRank = Self.kindRank(left.0.kind), rightRank = Self.kindRank(right.0.kind)
                if leftRank != rightRank { return leftRank < rightRank }
                if left.2 != right.2 { return left.2 < right.2 }
                return left.0.id < right.0.id
            }
            var seen = Set(answer.venues.map(\.id))
            for (venue, candidate, _) in ranked where answer.venues.count < venueLimit {
                guard seen.insert(venue.id).inserted else { continue }
                answer.venues.append(venue)
                if let former = candidate.former { answer.formerNames[venue.id] = former }
            }
            if let first = ranked.first { bestVenue = (venuePenalty(first.0.kind), first.1.tier.rawValue) }
        }

        // Улицы и дома.
        var bestStreet: (Int, Int)?
        if let book, !streets.isEmpty {
            let streetHint = streetPenalty
            if let house = query.house {
                var found: [(Address, Bool, Candidate, Double)] = []
                for (index, candidate) in streets {
                    let street = book.streets[index]
                    for (offset, address) in street.houses.enumerated() {
                        let key = street.houseKeys[offset]
                        guard key.hasPrefix(house) else { continue }
                        let point = book.addresses[address].point
                        found.append((book.addresses[address], key == house, candidate,
                                      near.map { Self.distance($0, point) } ?? 0))
                    }
                }
                found.sort { left, right in
                    if left.1 != right.1 { return left.1 }
                    if left.2.tier != right.2.tier { return left.2.tier < right.2.tier }
                    return left.3 < right.3
                }
                let distinct = AddressBook.distinct(found.map(\.0), limit: streetLimit)
                let former = Dictionary(found.map { ($0.0.id, $0.2.former) }, uniquingKeysWith: { first, _ in first })
                answer.addresses = distinct
                for address in distinct { if let name = former[address.id] ?? nil { answer.formerNames[address.id] = name } }
                if let first = found.first { bestStreet = (streetHint, first.2.tier.rawValue) }
            } else {
                var ranked: [(Address, Candidate, Double)] = []
                ranked.reserveCapacity(streets.count)
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
                    ranked.append((Address(street: street.name, house: "", point: book.addresses[pick].point),
                                   candidate, pickDistance))
                }
                ranked.sort { left, right in
                    if left.1.tier != right.1.tier { return left.1.tier < right.1.tier }
                    if left.1.extra != right.1.extra { return left.1.extra > right.1.extra }
                    if left.1.primary != right.1.primary { return left.1.primary }
                    if left.2 != right.2 { return left.2 < right.2 }
                    return left.0.street < right.0.street
                }
                for (address, candidate, _) in ranked.prefix(streetLimit) {
                    answer.addresses.append(address)
                    if let former = candidate.former { answer.formerNames[address.id] = former }
                }
                if let first = ranked.first { bestStreet = (streetHint, first.1.tier.rawValue) }
            }
        }

        switch (bestVenue, bestStreet) {
        case let (venue?, street?): answer.venuesFirst = venue <= street
        case (nil, _?): answer.venuesFirst = !answer.venues.isEmpty && answer.addresses.isEmpty
        default: answer.venuesFirst = true
        }
        return answer
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
    private func matches(_ word: String, typing: Bool) -> [Int32: UInt8] {
        var out: [Int32: UInt8] = [:]
        func mark(_ token: Int32, _ quality: UInt8) {
            for name in postings[Int(token)] {
                if let known = out[name], known <= quality { continue }
                out[name] = quality
            }
        }
        let bytes = Array(word.utf8)
        if let exact = tokenIDs[word] { mark(exact, 0) }
        // Начало слова — с двух букв: одна буква — это полгорода.
        if bytes.count >= 2 || word.first?.isNumber == true {
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

    /// Окончания русского падежа после fold: а, я(ya→a), ы/и(i), у, е.
    private static let endings: Set<UInt8> = [UInt8(ascii: "a"), UInt8(ascii: "i"),
                                              UInt8(ascii: "u"), UInt8(ascii: "e")]

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
