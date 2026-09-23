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
    /// Судьба штрафа — локальная копия: `pass` здесь слепок, а после тапа
    /// «Пришёл»/«Не пришёл» экран обязан показать новое состояние сразу.
    @State private var fineOutcome: PassedCamera.FineOutcome = .pending
    /// «А если бы» — из .task, не из body: пересчёт рейтинга периода попадал в
    /// кадры анимации подлёта (Map пишет position обратно на каждом кадре).
    @State private var whatIf: (tripScore: Int, periodRating: Int?, currentRating: Int?)?
    /// Развёрнутая карта проезда.
    @State private var showsFullMap = false
    /// Объяснения раскрыты. По умолчанию нет — экран начинается с ответа.
    @State private var showsDetails = false

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

    /// Скорость, как её ВИДИТ человек. Одно округление на весь экран: раньше
    /// скорость печаталась усечением (66,6 → 66), а превышение округлением
    /// (6,6 → 7), и карточка сообщала «66 км/ч» и «превышение на 7 км/ч» при
    /// лимите 60. Арифметика на экране обязана сходиться сама с собой.
    private var shownSpeedKmh: Int { Int(pass.speedKmh.rounded()) }

    /// Превышение от ПОКАЗАННОЙ скорости — не от сырой.
    private var shownOverKmh: Int? {
        pass.limitKmh.map { shownSpeedKmh - $0 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                map
                answerCard
                details
            }
            .padding(20)
        }
        .backport.scrollEdgeEffectStyle(.hard, for: .top)
        .background(Theme.background)
        .navigationTitle("Проезд камеры")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsFullMap) {
            // Своего экрана карты не заводим: PeriodMapSheet уже интерактивен,
            // умеет фокус на камере и карточку места. Здесь он получает ровно
            // один трек и один маркер — этого проезда.
            PeriodMapSheet(data: fullMapData, focus: fullMapMarker)
        }
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
            fineOutcome = pass.fineOutcome
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

    /// Мини-карта — витрина, но не тупик: тап разворачивает её в настоящую
    /// карту проездов (ту же, что открывает зона риска в Итогах). Жесты у
    /// самой Map по-прежнему отключены — иначе она крадёт прокрутку листа, —
    /// поэтому тап ловит кнопка поверх неё.
    private var map: some View {
        mapCanvas
            // Кнопка — ОТДЕЛЬНЫМ слоем поверх, а не обёрткой вокруг карты:
            // у Map жесты выключены, и обёртка унаследовала бы это выключение
            // на собственную область нажатия. Тап снова не делал бы ничего —
            // ровно тот баг, который здесь и чинится.
            .overlay {
                Button { showsFullMap = true } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Открыть карту проезда"))
                .accessibilityAddTraits(.isButton)
            }
            // Значок «развернуть» рисуется последним, чтобы лежать сверху, и
            // нажатий не перехватывает: работает вся площадь карты.
            .overlay(alignment: .topTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.rounded(15, .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(7)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(10)
                    .allowsHitTesting(false)
            }
    }

    private var mapCanvas: some View {
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

    /// Маркер этого проезда для развёрнутой карты. Один проезд — значит
    /// `times` = 1, а «с превышением» решаем той же штрафной ступенью, что и
    /// чип статуса: два разных ответа об одном проезде на двух экранах — это
    /// баг, а не оформление.
    private var fullMapMarker: PassMarker? {
        guard let coordinate = pass.coordinate else { return nil }
        let over = overKmh.map { FineSchedule.fine(overKmh: $0) > 0 } ?? false
        return PassMarker(cameraID: pass.cameraID, lat: coordinate.latitude,
                          lon: coordinate.longitude,
                          location: pass.location.isEmpty ? pass.kind.displayName : pass.location,
                          times: 1, overTimes: over ? 1 : 0,
                          maxSpeedKmh: pass.speedKmh, limitKmh: pass.limitKmh)
    }

    private var fullMapData: PeriodMapData {
        PeriodMapData(tracks: track.count >= 2 ? [track] : [],
                      markers: fullMapMarker.map { [$0] } ?? [])
    }

    // MARK: Ответ экрана — одна карточка

    /// Экран отвечает на один вопрос: «что было у этой камеры и во сколько это
    /// обошлось». Раньше ответ был размазан по шести блокам — карта, скорость,
    /// цена, «а если бы», «как считаем», «что-то не так», — и из них только
    /// первые два отвечали, а остальные объясняли. Объяснения уехали под
    /// «Подробнее»: они нужны один раз, а не при каждом открытии.
    private var answerCard: some View {
        VStack(spacing: 14) {
            speedSection
            costSection
        }
        .statCard()
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 18)
    }

    private var speedSection: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: pass.kind.symbolName)
                    .font(.rounded(15, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(pass.kind.tint.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(pass.location.isEmpty ? pass.kind.displayName : pass.location)
                        .font(.rounded(19, .bold))
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
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textTertiary)
                    // Герой карточки: ради этого числа экран и открывают.
                    // Кегль 30 против 12 у подписи — иерархия видна с одного
                    // взгляда, а не вычитывается.
                    Text("\(shownSpeedKmh) км/ч")
                        .font(.rounded(30, .heavy).monospacedDigit())
                        .foregroundStyle(honestyColor)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                statusChip
            }

            // Пол фиксации сработал — говорим об этом вслух. Молча поднятый
            // лимит выглядит как «приложение перепутало знак», а мы не про
            // знак: мы про то, с какой скорости камера штрафует.
            if pass.limitWasFloored, let road = pass.roadLimitKmh, let limit = pass.limitKmh {
                Text(String(format: String(localized:
                    "На дороге знак %lld, но камеры в городе фиксируют от %lld — считаем по %lld."),
                    road, limit, limit))
                    .font(.rounded(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var statusChip: some View {
        let fine = overKmh.map { FineSchedule.fine(overKmh: $0) } ?? 0
        if fine > 0 {
            VStack(alignment: .trailing, spacing: 2) {
                Label("превышение", systemImage: "exclamationmark.triangle.fill")
                    .font(.rounded(15, .bold))
                    .foregroundStyle(Theme.danger)
                if let over = shownOverKmh, over > 0 {
                    Text(String(format: String(localized: "на %lld км/ч"), over))
                        .font(.rounded(11, .semibold))
                        .foregroundStyle(Theme.danger)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.danger.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if pass.limitKmh != nil {
            Label("в лимите", systemImage: "checkmark.shield.fill")
                .font(.rounded(15, .bold))
                .foregroundStyle(Theme.success)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.success.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Label("лимит неизвестен", systemImage: "questionmark.circle")
                .font(.rounded(15, .bold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.stroke, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: Во сколько обошёлся

    /// Две цены одного проезда: баллы рейтинга и деньги. Живут В ТОЙ ЖЕ
    /// карточке, что и скорость: это не отдельная тема, это вторая половина
    /// одного ответа. Отдельной карточкой они добавляли на экран границу,
    /// заголовок и тень — три предмета ради двух строк.
    @ViewBuilder private var costSection: some View {
        let penalty = overKmh.map { DrivingScore.penaltyPoints(overKmh: $0) } ?? 0
        let fine = overKmh.map { FineSchedule.fine(overKmh: $0) } ?? 0
        if penalty > 0 || fine > 0 {
            Rectangle().fill(Theme.stroke).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                if penalty > 0 {
                    costRow(icon: "gauge.with.needle", tint: Theme.danger,
                            title: String(localized: "Снято с балла поездки"),
                            value: "−\(Int(penalty))")
                }
                if fine > 0 {
                    costRow(icon: "banknote",
                            tint: fineOutcome == .paid ? Theme.warning
                                : fineOutcome == .dismissed ? Theme.textTertiary
                                : Theme.danger,
                            title: fineTitle,
                            value: Formatting.money(fine))
                    // Судьба штрафа отмечается и отсюда: человек смотрит на
                    // конкретный проезд — незачем гонять его в общий список.
                    if record != nil {
                        fineOutcomeRow
                    }
                }
            }
        }
    }

    // MARK: Подробнее — то, что объясняет, а не отвечает

    /// «А если бы в лимите», метод расчёта и жалоба «не предупредила» нужны
    /// один раз: разобраться. Держать их раскрытыми при каждом открытии —
    /// значит каждый раз прятать ответ под объяснениями.
    private var details: some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            VStack(spacing: 16) {
                whatIfCard
                methodCard
                missedAlertCard
            }
            .padding(.top, 12)
        } label: {
            Text("Подробнее")
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .tint(Theme.textSecondary)
        .padding(.horizontal, 4)
    }

    private var fineTitle: String {
        switch fineOutcome {
        case .pending:   return String(localized: "Возможный штраф")
        case .paid:      return String(localized: "Штраф пришёл")
        case .dismissed: return String(localized: "Штраф не пришёл")
        }
    }

    /// Кнопки «Пришёл» / «Не пришёл» / «Вернуть» — тот же путь и та же
    /// хирургия сводок, что на экране возможных штрафов (TripStats).
    private var fineOutcomeRow: some View {
        HStack(spacing: 8) {
            if fineOutcome == .pending {
                fineButton(String(localized: "Пришёл"), symbol: "envelope.badge",
                           tint: Theme.warning, set: .paid)
                fineButton(String(localized: "Не пришёл"), symbol: "checkmark.circle",
                           tint: Theme.success, set: .dismissed)
            } else {
                fineButton(String(localized: "Вернуть"),
                           symbol: "arrow.uturn.backward.circle",
                           tint: Theme.textSecondary, set: .pending)
            }
            Spacer(minLength: 0)
        }
    }

    private func fineButton(_ title: String, symbol: String, tint: Color,
                            set outcome: PassedCamera.FineOutcome) -> some View {
        Button {
            guard let record else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.snappy(duration: 0.3)) {
                env.trip.setFineOutcome(outcome, passID: pass.id, tripID: record.id)
                fineOutcome = outcome
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.rounded(15, .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(tint.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private func costRow(icon: String, tint: Color, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.rounded(15, .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: Circle())
            Text(title)
                .font(.rounded(15, .medium))
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
                    .font(.rounded(15))
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
                .font(.rounded(15, .medium))
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
                .font(.rounded(15))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Лимит дороги — из OpenStreetMap, но ниже 60 км/ч мы по нему не судим: камеры в городе с меньшей скорости не фиксируют. Штраф — оценка первой фиксации: повторность нарушений и допуски конкретной камеры нам неизвестны.")
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
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.success)
            } else {
                Text("Если приложение промолчало об этой камере — скажите. Мы приложим место, скорость и лимит: без них найти причину невозможно.")
                    .font(.rounded(15))
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
