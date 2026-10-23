//
//  Attribution.swift
//  RadarMap
//
//  Чьё у нас внутри и на каких условиях (28.F, перед App Store).
//
//  Два списка, и разница между ними — юридическая, а не оформительская:
//  * `DataSource` — данные и их лицензии (ODbL, CC BY, CC BY-SA). Эти
//    лицензии требуют УПОМЯНУТЬ источник со ссылкой; для карты — «в углу
//    карты» (OpenMapTiles, правила OSMF), поэтому на карте есть «i».
//  * `ThirdPartyLicense` — код и шрифты, которые едут в бандле или рисуются
//    им. BSD требует ВОСПРОИЗВЕСТИ текст лицензии «в документации» бинарной
//    поставки, OFL — приложить лицензию к шрифту. Текст — английский
//    оригинал из `Resources/Licenses/`, дословно: перевод лицензии — уже
//    не та лицензия.
//
//  Откуда тексты (обновлять вместе с пакетом MapLibre):
//  * license-maplibre-native.txt — LICENSE.md пакета
//    maplibre-gl-native-distribution 6.29.0 (как лежит в SourcePackages);
//  * license-maplibre-native-ios.txt — platform/ios/LICENSE.md тега
//    ios-v6.29.0 репозитория maplibre-native: та же BSD плюс уведомления
//    вшитых в бинарь библиотек (Boost, RapidJSON, Metal-cpp, FreeType,
//    HarfBuzz…). В самом xcframework их нет, а BSD/Apache/FTL требуют их
//    в бинарной поставке;
//  * license-osm-bright.txt — LICENSE.md openmaptiles/osm-bright-gl-style:
//    наш стиль (server/omt/make_style.py, вшит как MapStyle/*.json) —
//    производный от OSM Bright;
//  * license-noto-sans.txt — noto-sans/LICENSE openmaptiles/fonts (OFL 1.1)
//    с копирайтом из таблицы name самого шрифта: подписи карты рисуются
//    глифами Noto Sans (server/omt/glyph_subset.py).
//

import Foundation

/// Источник данных: строка в «Источниках данных» со ссылкой.
nonisolated enum DataSource: CaseIterable, Sendable {
    case openMapTiles, openStreetMap, openData, openMeteo, osmBright

    /// Название лицензии — как его пишет сам лицензиар, не переводится.
    var licenseName: String {
        switch self {
        case .openMapTiles: return "CC BY 4.0"
        case .openStreetMap: return "ODbL 1.0"
        case .openData: return "CC BY-SA 4.0"
        case .openMeteo: return "CC BY 4.0"
        case .osmBright: return "BSD 3-Clause, CC BY 4.0"
        }
    }

    /// Куда ведёт строка: страница, которую лицензия велит указать.
    var url: URL {
        switch self {
        case .openMapTiles: return AppConfig.openMapTilesURL
        case .openStreetMap: return AppConfig.osmCopyrightURL
        case .openData: return AppConfig.openDataURL
        case .openMeteo: return AppConfig.openMeteoURL
        case .osmBright: return AppConfig.osmBrightURL
        }
    }

    /// Источники самой карты — их подпись стоит на карте и в листе «i».
    static let map: [DataSource] = [.openMapTiles, .openStreetMap]
}

/// Сторонний компонент, чью лицензию надо показать целиком.
nonisolated enum ThirdPartyLicense: String, CaseIterable, Identifiable, Sendable {
    case mapLibre, osmBright, notoSans

    var id: String { rawValue }

    /// Имя компонента — собственное, не переводится.
    var name: String {
        switch self {
        case .mapLibre: return "MapLibre Native"
        case .osmBright: return "OSM Bright"
        case .notoSans: return "Noto Sans"
        }
    }

    var licenseName: String {
        switch self {
        case .mapLibre: return "BSD 2-Clause"
        case .osmBright: return "BSD 3-Clause, CC BY 4.0"
        case .notoSans: return "SIL Open Font License 1.1"
        }
    }

    var url: URL {
        switch self {
        case .mapLibre: return AppConfig.mapLibreURL
        case .osmBright: return AppConfig.osmBrightURL
        case .notoSans: return AppConfig.notoFontsURL
        }
    }

    /// Файлы текста в бандле, по порядку показа.
    var resources: [String] {
        switch self {
        case .mapLibre: return ["license-maplibre-native", "license-maplibre-native-ios"]
        case .osmBright: return ["license-osm-bright"]
        case .notoSans: return ["license-noto-sans"]
        }
    }
}

/// Где на карте «i» с подписью данных.
nonisolated enum MapAttributionPlacement {
    /// Подъём над нижними панелями: в навигации угол занят кругом скорости.
    static func lift(speedPlacement: MapMode.SpeedPlacement, isAddingCamera: Bool) -> CGFloat {
        speedPlacement == .bottomLeading && !isAddingCamera ? AppConfig.mapAttributionSpeedLift : 0
    }
}

/// Текст лицензии для экрана.
nonisolated enum LicenseText {
    /// Разделитель между файлами одного компонента.
    static let fileSeparator = String(repeating: "=", count: 40)

    /// Читает файлы компонента из бандла. Нет файла — ошибка, а не пустой
    /// экран: лицензия, которую нельзя показать, — нарушение лицензии.
    static func load(_ license: ThirdPartyLicense, bundle: Bundle = .main) throws -> String {
        try license.resources.map { name in
            guard let url = bundle.url(forResource: name, withExtension: "txt") else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).txt"])
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n\n\(fileSeparator)\n\n")
    }

    /// Абзац без жёстких переносов: оригиналы свёрстаны под 72–80 знаков, и
    /// на экране телефона каждая строка ломалась надвое — «лесенка». Слова
    /// и их порядок не трогаем, склеиваем только строки, оборванные по
    /// ширине: строка короче `AppConfig.licenseReflowMinLine` — конец мысли
    /// (копирайт, заголовок), пункт списка и линейка всегда с новой строки.
    static func reflow(_ block: String) -> String {
        var lines: [String] = []
        var previousLength = 0
        for raw in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let last = lines.last, previousLength >= AppConfig.licenseReflowMinLine,
               !startsItem(line), !isRule(last) {
                lines[lines.count - 1] = last + " " + line
            } else {
                lines.append(line)
            }
            previousLength = raw.count
        }
        return lines.joined(separator: "\n")
    }

    /// Пункт списка: «* », «- », «1.», «2)», «(a)».
    private static func startsItem(_ line: String) -> Bool {
        if line.hasPrefix("* ") || line.hasPrefix("- ") || line.hasPrefix("• ") || isRule(line) { return true }
        let head = line.prefix(4)
        if let close = head.firstIndex(where: { $0 == "." || $0 == ")" }) {
            let label = head[..<close].drop(while: { $0 == "(" })
            return !label.isEmpty && label.allSatisfy { $0.isNumber || ($0.isLetter && label.count == 1) }
        }
        return false
    }

    /// Линейка-разделитель («=====», «-----»).
    private static func isRule(_ line: String) -> Bool {
        line.count >= 3 && line.allSatisfy { $0 == "=" || $0 == "-" }
    }

    /// Абзацы для ленивого списка: 100 КБ одним `Text` верстались бы целиком
    /// при каждом открытии. Режем по пустым строкам; переносы внутри абзаца
    /// и отступы остаются — в тексте лицензии они значимы.
    static func blocks(_ text: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.allSatisfy(\.isWhitespace) {
                if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
        return blocks
    }
}
