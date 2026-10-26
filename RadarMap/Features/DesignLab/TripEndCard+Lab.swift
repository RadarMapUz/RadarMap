//
//  TripEndCard+Lab.swift
//  RadarMap
//
//  Этап 31: три варианта карточки «Поездка сохранена» (`-designTripEnd A|B|C`).
//
//  Было: на SE заголовок переносится на две строки («Поездка / сохранена» —
//  ступень 17 прижимается к 19), «1 камер» без склонения, синяя градиентная
//  «Подробнее» спорит с жёлтой главной кнопкой экрана, а под карточкой
//  остаются «Домой» и «Начать поездку» — четыре слоя внизу.
//
//  A «Короче»       — вердикт главной строкой, «Поездка сохранена» — подписью;
//                     кнопка «Подробнее» нейтральная; склонение камер.
//  B «Балл-герой»   — одна строка высотой 96 pt: крупный балл слева, вердикт и
//                     «12,4 км · 18 мин · 1 камера»; вся карточка — кнопка.
//  C «С треком»     — сверху картинка трека (своя карта, снимок, не живая
//                     карта), балл на ней; ниже вердикт и цифры одной строкой.
//  Во всех: пока карточка на экране, «Домой» и «Начать поездку» под ней не
//  показываются (MapScreen+BottomPanels).
//

import SwiftUI
import CoreLocation

extension TripEndCard {

    /// «12,4 км · 18 мин · 1 камера» — склонение из каталога (`%lld камер`).
    var labFactsLine: String {
        [Formatting.distance(record.distanceMeters),
         Formatting.duration(record.movingDuration),
         String(localized: "\(record.camerasPassed) камер")].joined(separator: " · ")
    }

    private var labCardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
    }

    private var labClose: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.rounded(12, .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(Theme.background, in: Circle())
                .tapTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Скрыть итог поездки"))
    }

    /// Нейтральная «Подробнее» + «Поделиться»: жёлтая на экране одна, и это
    /// не она — синяя заливка спорила с ней за роль главной.
    private var labButtons: some View {
        HStack(spacing: 10) {
            Button { onDetail(record) } label: {
                HStack(spacing: 6) {
                    Text("Подробнее").font(.rounded(15, .semibold))
                    Image(systemName: "chevron.right").font(.rounded(12, .bold))
                }
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            Button(action: share) {
                Image(systemName: "square.and.arrow.up")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(Text("Поделиться поездкой"))
        }
    }

    // MARK: A — короче

    var labCardA: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                scoreBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text("Поездка сохранена")
                        .font(.rounded(12, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(moneyLine)
                        .font(.rounded(17, .bold))
                        .foregroundStyle(moneyTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
                labClose
            }
            HStack(spacing: 0) {
                metric(Formatting.distance(record.distanceMeters), String(localized: "путь"))
                metricDivider
                metric(Formatting.duration(record.movingDuration), String(localized: "в движении"))
                metricDivider
                metric(String(localized: "\(record.camerasPassed) камер"), String(localized: "пройдено"))
            }
            if let previous = mergeCandidate { mergeRow(previous: previous) }
            labButtons
        }
        .padding(14)
        .liftedBackground(Theme.surface, in: labCardShape)
        .overlay(labCardShape.strokeBorder(Theme.edgePanel, lineWidth: 1))
    }

    // MARK: B — балл-герой

    var labCardB: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button { onDetail(record) } label: {
                    HStack(spacing: 14) {
                        labHeroScore
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Поездка сохранена")
                                .font(.rounded(12, .semibold))
                                .foregroundStyle(Theme.textSecondary)
                            Text(moneyLine)
                                .font(.rounded(15, .bold))
                                .foregroundStyle(moneyTint)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Text(verbatim: labFactsLine)
                                .font(.rounded(12, .medium).monospacedDigit())
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.rounded(12, .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                VStack(spacing: 6) {
                    labClose
                    Button(action: share) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.rounded(13, .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 30, height: 30)
                            .background(Theme.background, in: Circle())
                            .tapTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Поделиться поездкой"))
                }
            }
            if let previous = mergeCandidate { mergeRow(previous: previous) }
        }
        .padding(14)
        .liftedBackground(Theme.surface, in: labCardShape)
        .overlay(labCardShape.strokeBorder(Theme.edgePanel, lineWidth: 1))
    }

    /// Балл крупно, без кольца: число и есть кольцо по смыслу, а цвет числа
    /// уже говорит «хорошо/плохо».
    @ViewBuilder private var labHeroScore: some View {
        if let score = record.score.map({ Int($0) }) {
            let tint = TripHistorySection.scoreColor(score)
            VStack(spacing: -2) {
                Text(verbatim: "\(score)")
                    .font(.rounded(38, .heavy).monospacedDigit())
                    .foregroundStyle(tint)
                Text("рейтинг")
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 70, height: 70)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        } else {
            scoreBadge.frame(width: 70, height: 70)
        }
    }

    // MARK: C — с треком

    var labCardC: some View {
        VStack(spacing: 0) {
            Group {
                if record.trackPoints.count >= 2 {
                    MapPictureView(key: "tripEnd|\(record.id)|\(record.passed.count)",
                                   picture: labPicture, height: 118)
                } else {
                    Theme.background.frame(height: 72)
                }
            }
            .overlay(alignment: .topLeading) {
                if let score = record.score.map({ Int($0) }) {
                    let tint = TripHistorySection.scoreColor(score)
                    HStack(spacing: 4) {
                        Text(verbatim: "\(score)")
                            .font(.rounded(19, .heavy).monospacedDigit())
                            .foregroundStyle(tint)
                        Text("рейтинг")
                            .font(.rounded(12, .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Theme.surface, in: Capsule())
                    .padding(10)
                }
            }
            .overlay(alignment: .topTrailing) {
                labClose.padding(8)
            }
            VStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Поездка сохранена")
                            .font(.rounded(15, .bold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(moneyLine)
                            .font(.rounded(12, .semibold))
                            .foregroundStyle(moneyTint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(verbatim: labFactsLine)
                        .font(.rounded(12, .medium).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                if let previous = mergeCandidate { mergeRow(previous: previous) }
                labButtons
            }
            .padding(14)
        }
        .clipShape(labCardShape)
        .liftedBackground(Theme.surface, in: labCardShape)
        .overlay(labCardShape.strokeBorder(Theme.edgePanel, lineWidth: 1))
    }

    private var labPicture: MapPicture {
        let points = record.trackPoints
        var picture = MapPicture()
        picture.lines = [.init(coordinates: points.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }, color: Theme.route, width: 4.5, casing: Theme.routeCasing, casingWidth: 8)]
        for pass in record.passed {
            guard let coordinate = pass.coordinate,
                  PassStyle.symbol(speed: pass.speedKmh, limit: pass.limitKmh) != nil else { continue }
            picture.dots.append(.init(coordinate: coordinate, diameter: 22,
                                      fill: PassStyle.color(speed: pass.speedKmh, limit: pass.limitKmh),
                                      ringWidth: 2, label: "\(Int(pass.speedKmh.rounded()))",
                                      labelColor: Theme.background))
        }
        if let start = points.first, let finish = points.last {
            picture.dots += TripEndpoints.dots(
                start: CLLocationCoordinate2D(latitude: start.lat, longitude: start.lon),
                finish: CLLocationCoordinate2D(latitude: finish.lat, longitude: finish.lon))
        }
        return picture
    }
}
