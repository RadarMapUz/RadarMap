//
//  CarPlayPanelText.swift
//  RadarMap
//
//  Строки узких панелей CarPlay: выбор маршрута и «…» плашки прибытия.
//
//  Пределы — из снимков CarPlay Simulator (AppConfig, «Панели CarPlay»): на
//  широком экране панель около 207 pt, в строке списка рядом со значком и
//  стрелками прокрутки остаётся около 105 pt. Система берёт первый вариант,
//  что помещается, но подпись переносит, а не укорачивает: поэтому длиннее
//  предела первым не идёт ничего.
//
//  Строка варианта (CPSRouteRowView, CarPlaySupport): заголовок — summary,
//  подпись — selection, а additional — только если selection пуст; первый
//  additional система показывает ещё и заметкой на карточке обзора.
//
//  Чистая логика; CarPlayPanelTextTests.
//

import Foundation

enum CarPlayPanelText {

    struct RouteLines: Equatable {
        let summary: [String]
        let additional: [String]
        let selection: [String]
    }

    struct CameraRow: Equatable {
        let title: String
        let detail: String
    }

    /// От длинного к короткому: длиннее предела первым не идёт, самый
    /// короткий вариант остаётся всегда.
    static func variants(_ candidates: [String], limit: Int) -> [String] {
        guard var kept = candidates.last.map({ [$0] }) else { return [] }
        for candidate in candidates.dropLast().reversed()
        where candidate.count >= kept[0].count && !kept.contains(candidate) {
            kept.insert(candidate, at: 0)
        }
        while kept.count > 1, kept[0].count > limit { kept.removeFirst() }
        return kept
    }

    /// Заголовок — метка и время, ниже — километры и камеры.
    static func route(label: String?, eta: String, distance: String, cameras: String,
                      titleLimit: Int = AppConfig.carPlayRouteTitleMaxChars,
                      detailLimit: Int = AppConfig.carPlayRouteDetailMaxChars) -> RouteLines {
        let title = [label.map { "\($0) · \(eta)" }, label, eta].compactMap { $0 }
        let facts = variants(["\(distance) · \(cameras)", distance], limit: detailLimit)
        return RouteLines(summary: variants(title, limit: titleLimit), additional: facts, selection: facts)
    }

    static func cameraRow(distance: String, kind: String, location: String) -> CameraRow {
        CameraRow(title: "\(distance) · \(kind)", detail: address(location))
    }

    /// Тип камеры для узкой строки: каждое слово целиком влезает в строку.
    static func kindName(_ type: CameraType,
                         wordLimit: Int = AppConfig.carPlayPanelKindWordMaxChars) -> String {
        switch type {
        case .intelligentRadar: return String(localized: "Камера и радар")
        case .mobileRadar:      return String(localized: "Мобильный радар")
        case .other(let raw):
            let fits = raw.split(whereSeparator: \.isWhitespace).allSatisfy { $0.count <= wordLimit }
            return fits && !raw.isEmpty ? raw : String(localized: "Камера")
        default:                return type.shortName
        }
    }

    /// Адрес из реестра: часть до запятой, затем целые слова в пределе.
    /// Слово длиннее строки система рвала бы посередине, поэтому на нём
    /// адрес заканчивается.
    static func address(_ location: String,
                        limit: Int = AppConfig.carPlayPanelAddressMaxChars,
                        wordLimit: Int = AppConfig.carPlayPanelAddressWordMaxChars) -> String {
        let head = ItogiCalendar.shortPlace(location)
        let tokens = head.split(whereSeparator: \.isWhitespace).map(String.init)
        var kept: [String] = []
        var length = 0
        for token in tokens {
            let next = length == 0 ? token.count : length + 1 + token.count
            guard token.count <= wordLimit, next <= limit else { break }
            kept.append(token)
            length = next
        }
        while let last = kept.last, connectors.contains(last.lowercased()) { kept.removeLast() }
        let text = tidied(kept.joined(separator: " "))
        if !text.isEmpty { return text }
        // Первое слово длиннее строки («Toshkent-oʻsh-…»): его первая часть.
        let piece = tokens.first?.split(whereSeparator: { partSeparators.contains($0) }).first.map(String.init) ?? head
        return String(tidied(piece).prefix(wordLimit))
    }

    private static let connectors: Set<String> = ["va", "и", "bilan", "—", "–", "-"]
    private static let partSeparators: Set<Character> = ["-", "–", "—", "/", "(", ")", "\"", "«", "»", "“", "”"]

    private static func tidied(_ text: String) -> String {
        var result = text.filter { !"\"«»“”".contains($0) }
        if result.filter({ $0 == "(" }).count > result.filter({ $0 == ")" }).count,
           let open = result.lastIndex(of: "(") {
            result = String(result[..<open])
        }
        return result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",.;:-–—(")))
    }
}

/// Единицы, которые машина печатает символом: `MeasurementFormatter`
/// подставляет слово системы только у стандартных единиц, а у своей — её
/// символ. CarPlay печатает по языку телефона, строки приложения — по своему.
nonisolated enum CarPlayUnits {
    private static let ruMeters = UnitLength(symbol: "м", converter: UnitConverterLinear(coefficient: 1))
    private static let ruKilometers = UnitLength(symbol: "км", converter: UnitConverterLinear(coefficient: 1000))
    private static let latinMeters = UnitLength(symbol: "m", converter: UnitConverterLinear(coefficient: 1))
    private static let latinKilometers = UnitLength(symbol: "km", converter: UnitConverterLinear(coefficient: 1000))

    static func meters(language: String = NumberFormat.locale.identifier) -> UnitLength {
        language == "uz" ? latinMeters : ruMeters
    }

    static func kilometers(language: String = NumberFormat.locale.identifier) -> UnitLength {
        language == "uz" ? latinKilometers : ruKilometers
    }
}
