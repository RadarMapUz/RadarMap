//
//  PeriodShareCard.swift
//  RadarMap
//
//  «Моя неделя за рулём» — шеринг-карточка периода: карта, главные цифры и
//  зона риска. Зона риска — самое вирусное: «где я рискую» интереснее голых
//  километров. Единственная карточка уровня статистики (карточка одной поездки
//  — TripShareCard в деталке).
//

import SwiftUI

struct PeriodShareCard: View {
    let summary: PeriodSummary
    let periodTitle: String
    var mapImage: UIImage? = nil
    var format: ShareFormat = .feed

    var body: some View {
        ShareCardShell(subtitle: periodTitle, format: format) {
            if let mapImage {
                ShareMapFrame(image: mapImage, height: format == .story ? 330 : 210)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 22)
            }

            // Герой: километры + дельта к прошлому периоду + кольцо рейтинга.
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Formatting.distance(summary.distance))
                            .font(.numeralFree(52, .heavy))
                            .foregroundStyle(.white)
                        // Процент — только у сопоставимых периодов, иначе
                        // километры (31E): «↗ 178 %» от девяти км уходило друзьям.
                        if let change = summary.distanceChange {
                            Label(change.percent.map { "\(abs($0))\u{00A0}%" }
                                    ?? Formatting.distance(abs(change.meters)),
                                  systemImage: change.isUp ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(change.isUp ? Theme.accent : .white.opacity(0.55))
                        }
                    }
                }
                Spacer(minLength: 0)
                if let rating = summary.rating {
                    RatingRing(rating: rating, animated: false)
                        .frame(width: 92, height: 92)
                }
            }
            .padding(.horizontal, 32)

            // Вердикт периода — честно, как на экране (ItogiRating.shareChip):
            // зелёная печать — только без штрафов И без «на грани».
            Group {
                switch ItogiRating.shareChip(summary) {
                case .risk(let place):
                    chip(symbol: PassVerdict.over.symbol, tint: PassVerdict.over.tint,
                         text: String(format: String(localized: "Зона риска: %@"), place))
                case .overspeed(let count):
                    chip(symbol: PassVerdict.over.symbol, tint: PassVerdict.over.tint,
                         text: String(format: String(localized: "Штрафуемых превышений: %lld"), count))
                case .edge(let count):
                    chip(symbol: PassVerdict.edge.symbol, tint: PassVerdict.edge.tint,
                         text: String(format: String(localized: "На грани у камер: %lld"), count))
                case .clean:
                    chip(symbol: "checkmark.seal.fill", tint: Theme.success,
                         text: String(localized: "Ни одного превышения у камер"))
                case nil:
                    EmptyView()
                }
            }
            .padding(.top, 16)

            // Одна растяжка вместо двух: раньше пробелы стояли и до героя, и
            // после чипа — при коротком наборе данных (нет рейтинга или чипа)
            // середина карточки зияла пустотой, что и было видно на дампе.
            Spacer(minLength: 12)

            HStack(spacing: 0) {
                ShareMetric(value: "\(summary.trips)",
                            label: Formatting.tripsLabel(summary.trips),
                            icon: "car.fill", tint: Theme.accent)
                ShareMetricDivider()
                // Проезды, не камеры (34): одна камера дважды была «2 камеры»,
                // а в «Итогах» то же число — «проезда камер».
                ShareMetric(value: "\(summary.cameras)",
                            label: Formatting.passesLabel(summary.cameras),
                            icon: "camera.fill", tint: Theme.Types.camera)
                ShareMetricDivider()
                ShareMetric(value: Formatting.duration(summary.movingDuration),
                            label: String(localized: "за рулём"),
                            icon: "clock.fill", tint: Theme.Icon.time)
            }
            .shareMetricsTile()
            .padding(.bottom, 4)
        }
    }

    private func chip(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
            Text(text)
                .font(.system(size: 18, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(Theme.quietFill, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
