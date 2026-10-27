//
//  PlaceMerge.swift
//  RadarMap
//
//  Одна улица — одна строка (34, снимок владельца 27.10): «Где ушло время»
//  показывало «улица Навои» двумя строками подряд — два медленных отрезка
//  одной улицы, разорванные светофором. Читается как ошибка, а по смыслу это
//  одно место: время на нём складывается.
//
//  Сливаются только строки с ОДНОЙ И ТОЙ ЖЕ известной улицей (без учёта
//  регистра и пробелов по краям). Безымянные места (nil или пусто) не
//  сливаются никогда: «1,2 км от дома» и «3,4 км от дома» — разные места.
//  Порядок — порядок первого появления; пересортировать по сумме — дело
//  вызывающего, у него своё «главное».
//
//  Чистая логика — PlaceMergeTests.
//

import Foundation

nonisolated enum PlaceMerge {

    static func byStreet<Item>(_ items: [Item], street: (Item) -> String?,
                               merge: (Item, Item) -> Item) -> [Item] {
        var result: [Item] = []
        var slot: [String: Int] = [:]
        for item in items {
            guard let key = normalized(street(item)) else {
                result.append(item)
                continue
            }
            if let index = slot[key] {
                result[index] = merge(result[index], item)
            } else {
                slot[key] = result.count
                result.append(item)
            }
        }
        return result
    }

    static func normalized(_ street: String?) -> String? {
        guard let trimmed = street?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}
