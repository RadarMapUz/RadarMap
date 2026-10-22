//
//  TripHistorySection.swift
//  RadarMap
//
//  Список поездок на экране Итогов: записи с баллом и мини-треком,
//  сгруппированные по дням. Выборку и заголовок задаёт экран (список подчиняется
//  фильтру периода), здесь только разметка и действия наверх.
//
//  Тап по строке открывает деталку поездки — ровно то, чего от списка ждут.
//  Раньше тап «применял» поездку к карте периода, а деталка пряталась за вторым
//  тапом в подписи под картой — красиво, но никто не догадывался. «Показать на
//  карте» осталось вторым жестом: в контекстном меню (для поездок с треком).
//

import SwiftUI
import CoreLocation

struct TripHistorySection: View {
    /// «Поездки за неделю» / «за месяц» / «Последние поездки» — приходит сверху.
    let title: String
    let records: [TripRecord]
    /// Какая поездка сейчас показана на карте.
    let selectedID: Double?
    let onShowOnMap: (TripRecord) -> Void
    let onOpenDetail: (TripRecord) -> Void
    let onRepeat: ((CLLocationCoordinate2D, String) -> Void)?
    let onDelete: (TripRecord) -> Void
    /// Ручная склейка: можно ли и объединить с предыдущей (см. TripMerge).
    var canMerge: ((TripRecord) -> Bool)? = nil
    var onMerge: ((TripRecord) -> Void)? = nil

    // Недельной карточки-сводки здесь больше нет: те же цифры (и глубже) даёт
    // герой периода наверху Итогов — двух источников правды быть не должно.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Без «Всего: N»: число поездок уже сказано в герое («Поездок: 8»),
            // а обрезанный список называет его на кнопке «Показать все (N)» (6.2).
            SectionHeader(title: title) { EmptyView() }

            ForEach(TripHistory.dayGroups(records), id: \.day) { group in
                Text(Formatting.dayTitle(group.day))
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                // Поездки дня — одной карточкой со строками (6.1): пять
                // отдельных карточек с тенью читались стопкой, а не списком,
                // и каждая тень пересчитывалась при прокрутке.
                VStack(spacing: 0) {
                    ForEach(Array(group.records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 {
                            Divider().overlay(Theme.stroke).padding(.leading, 70)
                        }
                        row(record)
                    }
                }
                // Подсветка выбранной строки не выходит за скругление карточки.
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                .statCard(padding: 0, radius: Theme.cornerMedium)
            }
        }
    }

    /// «1 остановка» / «3 остановки» — русские формы через словарь каталога.
    private func stopsLabel(_ count: Int) -> String {
        String(format: String(localized: "Остановок в пути: %lld"), count)
    }

    private func row(_ record: TripRecord) -> some View {
        let selected = selectedID == record.id
        return Button {
            onOpenDetail(record)
        } label: {
            HStack(spacing: 12) {
                trackThumbnail(record)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Formatting.clock(record.startedAt))
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    // Километры, время и камеры одной строкой: справа остаются
                    // только балл и шеврон — раньше там теснились три элемента.
                    HStack(spacing: 6) {
                        Text("\(Formatting.distance(record.distanceMeters)) · \(Formatting.duration(record.duration))")
                            .font(.rounded(15))
                            .foregroundStyle(Theme.textSecondary)
                        if record.camerasPassed > 0 {
                            Label("\(record.camerasPassed)", systemImage: "camera.fill")
                                .font(.rounded(11, .semibold))
                                .foregroundStyle(Theme.accent)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    // «Почему не 100» — прямо в строке: самая дорогая камера
                    // поездки. Раньше балл 55 объяснялся только в деталке.
                    if let worst = Self.worstPenalty(record) {
                        // «−25 баллов · Юнусабад»: голое «−25» читалось
                        // чем угодно — км/ч, минутами (6.3).
                        Text(verbatim: "−" + String(localized: "\(worst.points) баллов") + " · " + worst.place)
                            .font(.rounded(11, .medium))
                            .foregroundStyle(Theme.danger)
                            .lineLimit(1)
                    }
                    // Склеенная поездка: сразу видно, что внутри был заезд по пути.
                    if let stops = record.stops, !stops.isEmpty {
                        Label(stopsLabel(stops.count), systemImage: "pause.circle.fill")
                            .font(.rounded(11, .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 8)
                // Балл поездки — цвет по зоне, поездки сравниваешь с одного взгляда.
                if let score = record.score {
                    Text("\(Int(score))")
                        .font(.rounded(14, .heavy).monospacedDigit())
                        .foregroundStyle(Self.scoreColor(Int(score)))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Self.scoreColor(Int(score)).opacity(0.14), in: Capsule())
                }
                trailingIcon(record, selected: selected)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            // Выбранная поездка подсвечена акцентом — видно, что показано на карте.
            .background(selected ? Theme.accent.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // «Проявления» строк при прокрутке (scrollTransition) больше нет: оно
        // меняло прозрачность и масштаб каждой строки на каждом кадре, и
        // прокрутка перерисовывала строки целиком вместо того, чтобы их двигать.
        // Своя подпись затирала время, километры, балл и место — всё, что в
        // строке и написано. Оставляем производную, назначение — в hint.
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Открыть подробности"))
        .contextMenu {
            // «Подробнее» из меню ушло: это теперь основной тап по строке.
            if record.hasTrack {
                Button {
                    onShowOnMap(record)
                } label: {
                    Label("Показать на карте", systemImage: "map")
                }
            }
            if let onRepeat, let end = record.endCoordinate {
                Button {
                    onRepeat(end, String(localized: "Как в прошлый раз"))
                } label: {
                    Label("Повторить маршрут", systemImage: "arrow.triangle.turn.up.right.circle")
                }
            }
            // Починка лишнего разреза: стоп у магазина по привычке — и одна
            // поездка стала двумя. Симметрия к «Разделить здесь» в деталке.
            if let onMerge, canMerge?(record) == true {
                Button {
                    onMerge(record)
                } label: {
                    Label("Объединить с предыдущей", systemImage: "arrow.triangle.merge")
                }
            }
            Button(role: .destructive) {
                onDelete(record)
            } label: {
                Label("Удалить запись", systemImage: "trash")
            }
        }
    }

    /// Справа шеврон — тап открывает деталку. У поездки, «применённой» к карте
    /// периода (через контекстное меню), вместо него залитая карта: видно, чей
    /// трек сейчас наверху.
    private func trailingIcon(_ record: TripRecord, selected: Bool) -> some View {
        Image(systemName: selected ? "map.fill" : "chevron.right")
            .font(.rounded(selected ? 14 : 12, .semibold))
            .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
            .frame(width: 20)
    }

    /// Мини-силуэт трека — поездку узнаёшь с одного взгляда.
    @ViewBuilder private func trackThumbnail(_ record: TripRecord) -> some View {
        Group {
            // hasTrack существует ровно для этого: trackPoints разбирает
            // плоский массив заново, и без него строка списка делала это
            // дважды — на проверку и на отрисовку.
            if record.hasTrack {
                TrackCanvas(points: TrackCanvas.thinned(record.trackPoints,
                                                        to: AppConfig.trackThumbnailPoints),
                            lineWidth: 2, endpointSize: 7)
            } else {
                Image(systemName: "car.side")
                    .font(.rounded(15))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: 44, height: 44)
        .background(Theme.background.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Самая дорогая камера поездки — короткий ответ на «почему не 100».
    /// Считается по проездам (их единицы), трек не разбирается: строка списка
    /// не имеет права стоить дороже, чем она читается.
    static func worstPenalty(_ record: TripRecord) -> (points: Int, place: String)? {
        var worst: (points: Double, place: String)?
        for pass in record.passed {
            guard let limit = pass.limitKmh else { continue }
            let points = DrivingScore.penaltyPoints(overKmh: pass.speedKmh - Double(limit))
            guard points > 0, points > (worst?.points ?? 0) else { continue }
            worst = (points, pass.location.isEmpty ? pass.kind.displayName : pass.location)
        }
        return worst.map { (Int($0.points.rounded()), $0.place) }
    }

    /// Место самого дорогого ЖДУЩЕГО штрафа — пара к сумме риска. Лидер по
    /// баллам (`worstPenalty`) мог быть с отменённым штрафом или с
    /// предположенным лимитом, а в сумму риска такие проезды не входят.
    static func worstRiskPlace(_ record: TripRecord) -> String? {
        var best: (fine: Double, place: String)?
        for pass in record.passed where pass.limitIsCertain && pass.countsTowardFines {
            guard let limit = pass.limitKmh else { continue }
            let fine = FineSchedule.fine(overKmh: pass.speedKmh - Double(limit))
            guard fine > 0, fine > (best?.fine ?? 0) else { continue }
            best = (fine, pass.location.isEmpty ? pass.kind.displayName : pass.location)
        }
        return best?.place
    }

    static func scoreColor(_ score: Int) -> Color { Theme.score(score) }
}
