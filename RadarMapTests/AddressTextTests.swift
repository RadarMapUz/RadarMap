//
//  AddressTextTests.swift
//  RadarMapTests
//
//  Адреса камер — одним алфавитом (11.6): двойники внутри латинских слов,
//  адрес целиком кириллицей — в латиницу, чистые строки не тронуты.
//

import XCTest
@testable import RadarMap

final class AddressTextTests: XCTestCase {
    func testHomoglyphsInsideLatinWords() {
        XCTAssertEqual(AddressText.normalized("Mo‘minov Dаhаsi"), "Mo‘minov Dahasi")   // «а» — кириллица
        XCTAssertEqual(AddressText.normalized("Ulug‘bеk ko‘chasi"), "Ulug‘bek ko‘chasi")
        XCTAssertEqual(AddressText.normalized("Аmir Temur"), "Amir Temur")
        // Опечатки реестра — тоже латиницей.
        XCTAssertEqual(AddressText.normalized("Sаnъаt Punktи Aulы"), "Sanʼat Punkti Auli")
    }

    func testCyrillicOnlyAddressBecomesLatin() {
        XCTAssertEqual(AddressText.normalized("Алишер Навоий - Пахтакор Кўчаси"),
                       "Alisher Navoiy - Paxtakor Ko‘chasi")
        XCTAssertEqual(AddressText.normalized("Янги Юнусобод - Юнусота Кўчалари Чорраҳаси"),
                       "Yangi Yunusobod - Yunusota Ko‘chalari Chorrahasi")
        XCTAssertEqual(AddressText.normalized("Ер"), "Yer")
    }

    func testCleanTextIsUntouched() {
        for text in ["A-373 \"toshkent-o‘sh\" 321 KM", "Amir Temur ko‘chasi", ""] {
            XCTAssertEqual(AddressText.normalized(text), text)
        }
    }

    /// База v12 целиком: после нормализации ни одного смешанного слова.
    func testBundledDatabaseHasNoMixedWords() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "cameras", withExtension: "json"))
        let cameras = CameraStore.normalizedLabels(
            try JSONDecoder().decode([Camera].self, from: Data(contentsOf: url)))
        let mixed = cameras.filter { camera in
            camera.location.split(separator: " ").contains { word in
                word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
                    && word.unicodeScalars.contains { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
            }
        }
        XCTAssertEqual(mixed.map(\.id), [])
    }

    /// История: подписи камер базы приведены, свои и отметки водителей — нет.
    func testHistoryLabelsOfDatabaseCamerasOnly() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func pass(_ id: Int, _ location: String) -> PassedCamera {
            PassedCamera(id: UUID(), cameraID: id, typeRaw: "Стационар радар", location: location, speedKmh: 70,
                         date: start, lat: 41.31, lon: 69.28, limitKmh: 60)
        }
        let record = TripRecord(id: 1, startedAt: start, endedAt: start.addingTimeInterval(600),
                                distanceMeters: 5_000, maxSpeedKmh: 70,
                                passed: [pass(37, "Dаhаsi"), pass(1_000_002, "Моя камера"), pass(2_000_003, "")])
        let (normalized, changed) = TripHistory.labelsNormalized([record])
        XCTAssertTrue(changed)
        XCTAssertEqual(normalized[0].passed.map(\.location), ["Dahasi", "Моя камера", ""])
        XCTAssertFalse(TripHistory.labelsNormalized(normalized).1, "второй прогон ничего не меняет")
    }
}
