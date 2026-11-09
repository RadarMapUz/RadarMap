//
//  TripShareCard.swift
//  RadarMap
//
//  Карточка поездки для соцсетей (картинка 1080×1350 или 1080×1920): карта во
//  всю ширину, балл кольцом на её краю, вывод словами и три числа. Без карты
//  (офлайн) — трек на тёмном поле в том же месте.
//

import SwiftUI
import UIKit

struct TripShareCard: View {
    let record: TripRecord
    var mapImage: UIImage? = nil
    var format: ShareFormat = .feed

    private var heroHeight: CGFloat { format == .story ? 560 : 380 }

    var body: some View {
        ShareCardShell(subtitle: Formatting.dateAndClock(record.startedAt), format: format, headerOverHero: true) {
            hero

            HStack(spacing: 16) {
                if let score = record.score {
                    RatingRing(rating: Int(score), animated: false)
                        .frame(width: 104, height: 104)
                        .padding(7)
                        .background(Theme.background, in: Circle())
                }
                verdictLine
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, -66)

            Spacer(minLength: 10)

            HStack(spacing: 10) {
                ShareStatTile(value: Formatting.duration(record.duration), label: String(localized: "в пути"),
                              icon: "clock.fill", tint: Theme.Stats.commuteTop)
                ShareStatTile(value: Formatting.distance(record.distanceMeters), label: String(localized: "путь"),
                              icon: "point.topleft.down.to.point.bottomright.curvepath", tint: Theme.Stats.otherTop)
                // Максимальной скорости здесь нет: карточкой хвастаются, а
                // «104 км/ч» не достижение приложения про штрафы.
                ShareStatTile(value: "\(record.camerasPassed)", label: Formatting.camerasLabel(record.camerasPassed),
                              icon: "camera.fill", tint: Theme.Types.camera)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder private var hero: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let mapImage {
                    ShareMapFrame(image: mapImage, height: heroHeight, corner: 0)
                } else {
                    TrackCanvas(points: record.trackPoints, passes: record.passed, lineWidth: 5)
                        .frame(maxWidth: .infinity)
                        .frame(height: heroHeight)
                }
            }
            // Шапка читается на любой карте, а низ карты перетекает в поле карточки.
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 130)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, Theme.background], startPoint: .top, endPoint: .bottom)
                    .frame(height: 130)
            }
            if mapImage != nil {
                Text(verbatim: "© OpenStreetMap")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.trailing, 32)
                    .padding(.top, 58)
            }
        }
    }

    private struct Verdict {
        let icon: String
        let text: String
        let tint: Color
    }

    @ViewBuilder private var verdictLine: some View {
        let verdict = self.verdict
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: verdict.icon)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(verdict.tint)
            Text(verdict.text)
                .font(.rounded(23, .heavy))
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Решает `TripRecord.verdict`: карточку отправляют наружу, и «в лимите»
    /// после превышения было бы враньём в пользу водителя.
    private var verdict: Verdict {
        switch record.verdict {
        case .risk(let risk):
            // Место — самого дорогого ЖДУЩЕГО штрафа: лидер по баллам мог быть
            // с отменённым штрафом или предположенным лимитом.
            let place = TripHistorySection.worstRiskPlace(record)
            return Verdict(icon: "exclamationmark.triangle.fill",
                           text: place.map {
                               String(format: String(localized: "Может прийти ≈ %1$@ · %2$@"), Formatting.money(risk), $0)
                           } ?? String(format: String(localized: "Может прийти ≈ %@"), Formatting.money(risk)),
                           tint: Theme.danger)
        case .overspeed(let count):
            return Verdict(icon: "exclamationmark.triangle.fill",
                           text: String(format: String(localized: "Штрафуемых превышений: %lld"), count),
                           tint: Theme.danger)
        case .edge(let count):
            return Verdict(icon: Theme.symbol(.attention) ?? "exclamationmark.circle.fill",
                           text: String(format: String(localized: "На грани у камер: %lld"), count),
                           tint: Theme.warning)
        case .clean:
            // Не «Все камеры в лимите»: у части камер лимит мог быть неизвестен.
            return Verdict(icon: "checkmark.seal.fill", text: String(localized: "Без штрафуемых превышений"),
                           tint: Theme.success)
        case .unknownLimits, .noCameras:
            return Verdict(icon: "flag.checkered", text: String(localized: "Поездка завершена"), tint: Theme.accent)
        }
    }
}

/// Плитка числа на карточке: значок в цветном круге, значение, подпись.
struct ShareStatTile: View {
    let value: String
    let label: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.18), in: Circle())
            Text(value)
                .font(.numeralFree(22, .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
