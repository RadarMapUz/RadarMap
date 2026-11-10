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
            // Пустой заголовок — на странице «Поездки» (34b): навбар и строка
            // окна над списком уже говорят «поездки за неделю».
            if !title.isEmpty {
                SectionHeader(title: title) { EmptyView() }
            }

            ForEach(TripHistory.dayGroups(records), id: \.day) { group in
                Text(Formatting.dayTitle(group.day))
                    .font(.rounded(12, .semibold))
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

    private func row(_ record: TripRecord) -> some View {
        Button {
            onOpenDetail(record)
        } label: {
            TripListRow(record: record, title: Formatting.clock(record.startedAt),
                        selected: selectedID == record.id)
        }
        .buttonStyle(PressableStyle(.row))
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

    /// Самая дорогая камера поездки — короткий ответ на «почему не 100».
    /// Считается по проездам (их единицы), трек не разбирается: строка списка
    /// не имеет права стоить дороже, чем она читается.
    /// `edge` — проезд «на грани» (PassVerdict): строка жёлтая, не красная.
    static func worstPenalty(_ record: TripRecord) -> (points: Int, place: String, edge: Bool)? {
        var worst: (points: Double, place: String, edge: Bool)?
        for pass in record.passed {
            guard let limit = pass.limitKmh else { continue }
            let points = DrivingScore.penaltyPoints(overKmh: pass.speedKmh - Double(limit))
            guard points > 0, points > (worst?.points ?? 0) else { continue }
            worst = (points, pass.location.isEmpty ? pass.kind.displayName : pass.location,
                     pass.verdict == .edge)
        }
        return worst.map { (Int($0.points.rounded()), $0.place, $0.edge) }
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


/// Строка поездки — одна на список периода и «Архив поездок» (38C): архив
/// показывал свою строку, без превью трека, камер и «почему не 100», и одна
/// и та же поездка выглядела в двух списках по-разному. Заголовок задаёт
/// список: в дне — время, в архиве (по месяцам) — дата и время.
struct TripListRow: View {
    let record: TripRecord
    let title: String
    /// «→ Дом» / «→ Работа» — куда приехали (архив).
    var finish: TripArchive.Finish? = nil
    /// Поездка «применена» к карте периода.
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            trackThumbnail
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    // Куда приехали — значком места, не стрелкой-символом:
                    // строку узнают по цели, а не по времени старта.
                    if let finish {
                        Label {
                            // Две строки каталога, не тернарник литералов (правило 7).
                            Text(finish == .home ? String(localized: "Дом") : String(localized: "Работа"))
                        } icon: {
                            SymbolIcon(finish == .home ? "house.fill" : "briefcase.fill", size: 11)
                        }
                        .labelStyle(.titleAndIcon)
                        .font(.rounded(12, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
                // «14,2 км · 41 мин · 6 камер» — одной подписью 13 pt
                // (аудит 05.11): справа остаются только балл и шеврон.
                Text(factsLine)
                    .font(.rounded(13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                // «Почему не 100» — прямо в строке: самая дорогая камера
                // поездки, словами «к баллу» — голое «−25» читалось чем
                // угодно, а «баллов» путалось с рейтингом недели.
                if let worst = TripHistorySection.worstPenalty(record) {
                    Text(String(format: String(localized: "%1$@ к баллу · %2$@"),
                                Formatting.points(worst.points), worst.place))
                        .font(.rounded(13, .medium))
                        .foregroundStyle(worst.edge ? PassVerdict.edge.tint : PassVerdict.over.tint)
                        .lineLimit(2)
                }
                // Склеенная поездка: сразу видно, что внутри был заезд по пути.
                if let stops = record.stops, !stops.isEmpty {
                    Label(String(format: String(localized: "Остановок в пути: %lld"), stops.count),
                          systemImage: "pause.circle.fill")
                        .font(.rounded(12, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            // «балл 55» — балл поездки, не рейтинг (аудит, п. 4); цвет по зоне.
            if let score = record.score {
                VStack(spacing: 0) {
                    Text("\(Int(score))")
                        .font(.rounded(15, .heavy).monospacedDigit())
                        .foregroundStyle(TripHistorySection.scoreColor(Int(score)))
                    Text("балл")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(minWidth: 40)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(String(format: String(localized: "Балл поездки: %lld"), Int(score))))
            }
            trailingIcon
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        // Выбранная поездка подсвечена акцентом — видно, что показано на карте.
        .background(selected ? Theme.quietFill : .clear)
        .contentShape(Rectangle())
    }

    private var factsLine: String {
        var parts = [Formatting.distance(record.distanceMeters), Formatting.duration(record.duration)]
        if record.camerasPassed > 0 {
            parts.append("\(record.camerasPassed)\u{00A0}" + Formatting.camerasLabel(record.camerasPassed))
        }
        return parts.joined(separator: " · ")
    }

    /// Справа шеврон — тап открывает деталку. У поездки, «применённой» к карте
    /// периода (через контекстное меню), вместо него залитая карта: видно, чей
    /// трек сейчас наверху.
    private var trailingIcon: some View {
        Image(systemName: selected ? "map.fill" : "chevron.right")
            .font(.rounded(selected ? 14 : 12, .semibold))
            .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
            .frame(width: 20)
    }

    /// Мини-силуэт трека — поездку узнаёшь с одного взгляда.
    private var trackThumbnail: some View {
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
}

#if DEBUG
#Preview("Строка поездки · список и архив · SE") {
    let start = Date().addingTimeInterval(-86_400)
    let pass = PassedCamera(id: UUID(), cameraID: 1, typeRaw: "Стационар радар",
                            location: "Юнусабад", speedKmh: 88, date: start.addingTimeInterval(600),
                            lat: 41.31, lon: 69.28, limitKmh: 60)
    let record = TripRecord(id: start.timeIntervalSince1970, startedAt: start,
                            endedAt: start.addingTimeInterval(1_080), distanceMeters: 12_400,
                            maxSpeedKmh: 88, passed: [pass], score: 55)
    return VStack(spacing: 0) {
        TripListRow(record: record, title: Formatting.clock(record.startedAt))
        Divider().overlay(Theme.stroke).padding(.leading, 70)
        TripListRow(record: record,
                    title: Formatting.dateAndClock(record.startedAt, .dateTime.day().month(.abbreviated)),
                    finish: .work)
    }
    .statCard(padding: 0, radius: Theme.cornerMedium)
    .padding(20)
    .frame(width: 375)
    .background(Theme.background)
}
#endif
