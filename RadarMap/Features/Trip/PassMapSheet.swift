//
//  PassMapSheet.swift
//  RadarMap
//
//  Проезд камеры — нижний уровень разбора рейтинга и конец цепочки
//  «рейтинг → поездка → камера». Карта подлетает к точке, дальше идут ответы
//  на три вопроса, которые водитель задаёт именно здесь: с какой скоростью я
//  её прошёл, во сколько это обошлось (баллы и штраф) и что было бы, проедь
//  я в лимите.
//
//  Раньше экран показывал только карту и скорость: строка «−25 за Юнусабад»
//  в разборе балла оставалась утверждением, которое нечем проверить.
//

import SwiftUI
import MapKit

/// Содержимое без своей навигации: шитом из деталки поездки и уровнем стека
/// из разбора рейтинга — один и тот же экран.
struct PassDetailView: View {
    let pass: PassedCamera
    /// Трек поездки вокруг камеры — виден контекст: откуда ехал и куда.
    var track: [TrackPoint] = []
    /// Поездка, в которой был проезд: из неё считаются снятые баллы.
    var record: TripRecord? = nil
    /// Контекст периода. Без него «а если бы» отвечает только про поездку.
    var days: [TripDay] = []
    var interval: DateInterval? = nil
    var period: StatsPeriod? = nil

    @Environment(AppEnvironment.self) private var env
    @State private var position: MapCameraPosition
    @State private var appeared = false
    @State private var isSendingMissed = false
    @State private var missedSent = false
    /// «А если бы» — из .task, не из body: пересчёт рейтинга периода попадал в
    /// кадры анимации подлёта (Map пишет position обратно на каждом кадре).
    @State private var whatIf: (tripScore: Int, periodRating: Int?, currentRating: Int?)?

    init(pass: PassedCamera, track: [TrackPoint] = [], record: TripRecord? = nil,
         days: [TripDay] = [], interval: DateInterval? = nil, period: StatsPeriod? = nil) {
        self.pass = pass
        self.track = track
        self.record = record
        self.days = days
        self.interval = interval
        self.period = period
        let center = pass.coordinate ?? CLLocationCoordinate2D(latitude: 41.3111,
                                                               longitude: 69.2797)
        // Старт издалека и сверху — при появлении камера красиво подлетает.
        _position = State(initialValue: .camera(
            MapCamera(centerCoordinate: center, distance: 14_000)))
    }

    private var honestyColor: Color {
        PassStyle.color(speed: pass.speedKmh, limit: pass.limitKmh)
    }

    /// Превышение относительно лимита дороги; nil — лимит неизвестен и судить
    /// о нарушении мы не вправе.
    private var overKmh: Double? { pass.overLimitKmh }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                map
                speedCard
                costCard
                whatIfCard
                methodCard
                missedAlertCard
            }
            .padding(20)
        }
        .backport.scrollEdgeEffectStyle(.hard, for: .top)
        .background(Theme.background)
        .navigationTitle("Проезд камеры")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let record, pass.limitKmh != nil,
                  let tripScore = RatingBreakdown.tripScoreIfClean(pass: pass, record: record)
            else { return }
            let periodRating = interval.flatMap { window in
                RatingBreakdown.ratingIfClean(pass: pass, record: record,
                                              days: days, in: window)
            }
            let current = interval.map { TripDayBook.summary(days, in: $0).rating } ?? nil
            whatIf = (tripScore, periodRating, current)
        }
        .onAppear {
            guard let coordinate = pass.coordinate else { return }
            // Подлёт: с высоты — к камере, с лёгким наклоном для объёма.
            withAnimation(.spring(duration: 1.6, bounce: 0.12).delay(0.25)) {
                position = .camera(MapCamera(centerCoordinate: coordinate,
                                             distance: 1300, pitch: 48))
            }
            withAnimation(.spring(duration: 0.6, bounce: 0.2).delay(0.5)) {
                appeared = true
            }
        }
    }

    // MARK: Карта

    private var map: some View {
        Map(position: $position) {
            if track.count >= 2 {
                MapPolyline(coordinates: track.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                })
                .stroke(LinearGradient(colors: [Theme.accent, Theme.Types.intelligent],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let coordinate = pass.coordinate {
                Annotation("", coordinate: coordinate, anchor: .center) {
                    PassPulseMarker(color: honestyColor, icon: pass.kind.symbolName)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll,
                            showsTraffic: false))
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
            .stroke(Theme.stroke, lineWidth: 1))
        // Статичная витрина: жесты карты не крадём у прокрутки.
        .allowsHitTesting(false)
    }

    // MARK: Скорость против лимита

    private var speedCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: pass.kind.symbolName)
                    .font(.rounded(15, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(pass.kind.tint.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(pass.location.isEmpty ? pass.kind.displayName : pass.location)
                        .font(.rounded(16, .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text("\(pass.kind.displayName) · \(pass.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)

            HStack(spacing: 14) {
                if let limit = pass.limitKmh {
                    SpeedLimitSign(limit: limit, diameter: 44)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("ваша скорость")
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textTertiary)
                    Text("\(Int(pass.speedKmh)) км/ч")
                        .font(.rounded(22, .heavy).monospacedDigit())
                        .foregroundStyle(honestyColor)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                statusChip
            }
        }
        .statCard()
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 18)
    }

    @ViewBuilder private var statusChip: some View {
        let fine = overKmh.map { FineSchedule.fine(overKmh: $0) } ?? 0
        if fine > 0 {
            VStack(alignment: .trailing, spacing: 2) {
                Label("превышение", systemImage: "exclamationmark.triangle.fill")
                    .font(.rounded(12, .bold))
                    .foregroundStyle(Theme.danger)
                if let over = overKmh {
                    Text(String(format: String(localized: "на %lld км/ч"), Int(over.rounded())))
                        .font(.rounded(11, .semibold))
                        .foregroundStyle(Theme.danger)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.danger.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if pass.limitKmh != nil {
            Label("в лимите", systemImage: "checkmark.shield.fill")
                .font(.rounded(12, .bold))
                .foregroundStyle(Theme.success)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.success.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Label("лимит неизвестен", systemImage: "questionmark.circle")
                .font(.rounded(12, .bold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.stroke, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: Во сколько обошёлся

    /// Две цены одного проезда: баллы рейтинга и деньги. Раньше их приходилось
    /// собирать по двум разным экранам.
    @ViewBuilder private var costCard: some View {
        let penalty = overKmh.map { DrivingScore.penaltyPoints(overKmh: $0) } ?? 0
        let fine = overKmh.map { FineSchedule.fine(overKmh: $0) } ?? 0
        if penalty > 0 || fine > 0 {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(String(localized: "Во сколько обошёлся"))
                if penalty > 0 {
                    costRow(icon: "gauge.with.needle", tint: Theme.danger,
                            title: String(localized: "Снято с балла поездки"),
                            value: "−\(Int(penalty))")
                }
                if fine > 0 {
                    costRow(icon: "banknote", tint: Theme.danger,
                            title: String(localized: "Возможный штраф"),
                            value: Formatting.money(fine))
                }
            }
            .statCard()
        }
    }

    private func costRow(icon: String, tint: Color, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.rounded(13, .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: Circle())
            Text(title)
                .font(.rounded(13, .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.rounded(16, .heavy).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: А если бы в лимите

    /// Цена вопроса в тех же единицах, что и весь разбор. Считается по той же
    /// лестнице баллов, что и сам рейтинг, — это не «прогноз», а проверяемая
    /// арифметика на уже случившихся данных. Числа готовит .task.
    @ViewBuilder private var whatIfCard: some View {
        if let record, let limit = pass.limitKmh, let whatIf {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(String(localized: "А если бы в лимите"))
                Text(String(format: String(localized: "Пройди вы эту камеру на %lld км/ч:"), limit))
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
                if let score = record.score {
                    whatIfRow(title: String(localized: "балл поездки"),
                              from: Int(score.rounded()), to: whatIf.tripScore)
                }
                if let periodRating = whatIf.periodRating, let period {
                    whatIfRow(title: String(format: String(localized: "рейтинг %@"),
                                            period.caption),
                              from: whatIf.currentRating ?? periodRating, to: periodRating)
                }
            }
            .statCard()
        }
    }

    private func whatIfRow(title: String, from: Int, to: Int) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.rounded(13, .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Text("\(from)")
                .font(.rounded(15, .bold).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Image(systemName: "arrow.right")
                .font(.rounded(11, .bold))
                .foregroundStyle(Theme.textTertiary)
            Text("\(to)")
                .font(.rounded(19, .heavy).monospacedDigit())
                .foregroundStyle(to > from ? Theme.success : Theme.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Как считаем

    private var methodCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(String(localized: "Как мы считаем скорость"))
            Text("Берём минимальную скорость в зоне 80 м перед камерой — так же, как измеряет она сама. Разгон сразу после проезда в расчёт не идёт.")
                .font(.rounded(13))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Лимит дороги — из OpenStreetMap. Штраф — оценка первой фиксации: повторность нарушений и допуски конкретной камеры нам неизвестны.")
                .font(.rounded(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .statCard()
    }

    // MARK: Жалоба «не предупредила»

    /// Молчание о настоящей камере — худшая из наших ошибок, и до сих пор
    /// сообщить о ней было негде: в отзыве «иногда не предупреждает» нет ни
    /// места, ни скорости, ни маршрута, то есть воспроизвести нечего.
    /// Здесь весь контекст уже известен — остаётся один тап.
    @ViewBuilder
    private var missedAlertCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(String(localized: "Что-то не так с этим проездом?"))
            if missedSent {
                Label(String(localized: "Спасибо — разберёмся"), systemImage: "checkmark.circle.fill")
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.success)
            } else {
                Text("Если приложение промолчало об этой камере — скажите. Мы приложим место, скорость и лимит: без них найти причину невозможно.")
                    .font(.rounded(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    sendMissedAlert()
                } label: {
                    HStack(spacing: 8) {
                        if isSendingMissed {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "speaker.slash.fill")
                        }
                        Text("Не предупредила о камере")
                    }
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.warning)
                }
                .buttonStyle(.plain)
                .disabled(isSendingMissed)
            }
        }
        .statCard()
    }

    private func sendMissedAlert() {
        guard !isSendingMissed else { return }
        isSendingMissed = true
        Task {
            _ = await env.feedback.reportMissedAlert(
                pass: pass,
                dbVersion: env.cameras.dbVersion)
            isSendingMissed = false
            // Очередь оффлайна — тоже успех: жалоба уйдёт, когда появится сеть.
            missedSent = true
        }
    }
}

// MARK: - Шит-обёртка

/// Из деталки поездки проезд открывается шитом — как и раньше.
struct PassMapSheet: View {
    let pass: PassedCamera
    var track: [TrackPoint] = []
    var record: TripRecord? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PassDetailView(pass: pass, track: track, record: record)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Пульсирующий маркер проезда

/// Маленький слой с одним повторяющимся кольцом — GPU-нагрузка ничтожна,
/// живёт только пока открыт этот экран.
private struct PassPulseMarker: View {
    let color: Color
    let icon: String
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(pulse ? 0 : 0.55), lineWidth: 2.5)
                .frame(width: 36, height: 36)
                .scaleEffect(pulse ? 2.7 : 1)
            Circle()
                .fill(color.gradient)
                .frame(width: 38, height: 38)
                .shadow(color: color.opacity(0.65), radius: 9)
            Image(systemName: icon)
                .font(.rounded(15, .bold))
                .foregroundStyle(.white)
        }
        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2).frame(width: 38, height: 38))
        .onAppear {
            withAnimation(.easeOut(duration: 1.7).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}
