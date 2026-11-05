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
    @State private var appeared = false
    @State private var isSendingMissed = false
    @State private var missedSent = false
    /// Судьба штрафа — локальная копия: `pass` здесь слепок, а после тапа
    /// «Пришёл»/«Не пришёл» экран обязан показать новое состояние сразу.
    @State private var fineOutcome: PassedCamera.FineOutcome = .pending
    /// «А если бы» — из .task, не из body: пересчёт рейтинга периода не должен
    /// попадать в кадры анимации появления.
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
    }

    private var honestyColor: Color {
        PassStyle.color(speed: pass.speedKmh, limit: pass.limitKmh)
    }

    /// Проезд снял баллы — «в лимите» или «на грани» решает PassVerdict.
    private var costsPoints: Bool {
        (overKmh.map { DrivingScore.penaltyPoints(overKmh: $0) } ?? 0) > 0
    }

    /// Превышение относительно лимита дороги; nil — лимит неизвестен и судить
    /// о нарушении мы не вправе.
    private var overKmh: Double? { pass.overLimitKmh }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                map
                answerCard
                // Промолчали об этой камере — жалоба сразу под ответом (6.7):
                // это худшая наша ошибка, и прятать её в «Подробнее» нельзя.
                if pass.silent == true { missedAlertCard }
                // «А если бы в лимите» открыт, когда проезд снял баллы (аудит
                // 05.11): это и есть ответ на «за что −8», а не справка.
                if costsPoints { whatIfCard }
                details
            }
            .padding(20)
        }
        .backport.scrollEdgeEffectStyle(.hard, for: .top)
        .background(Theme.background)
        .navigationTitle("Проезд камеры")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { env.usage.noteScreen("pass") }
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
            withMotion(.spring(duration: 0.6, bounce: 0.2).delay(0.5)) {
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

    /// Снимок, а не живая 3D-карта (6.7): в листе она жила ради одного
    /// подлёта, держала GPU и подгружала тайлы, а жесты у неё всё равно были
    /// выключены. Кадр — участок трека у камеры, а не вся поездка: на 20 км
    /// камера была бы точкой. Тап по-прежнему открывает настоящую карту.
    private var mapCanvas: some View {
        MapPictureView(key: "pass:\(pass.id.uuidString)", picture: passPicture, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1))
            .allowsHitTesting(false)
    }

    private var passPicture: MapPicture {
        var picture = MapPicture()
        let near: [TrackPoint]
        if let camera = pass.coordinate {
            near = track.filter {
                GeoMath.fastDistance($0.lat, $0.lon, camera.latitude, camera.longitude)
                    <= AppConfig.passPictureTrackMeters
            }
        } else {
            near = track
        }
        let line = near.count >= 2 ? near : track
        if line.count >= 2 {
            picture.lines = [.init(coordinates: line.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
            }, color: Theme.route, width: 4.5, casing: Theme.routeCasing, casingWidth: 8)]
        }
        if let camera = pass.coordinate {
            picture.dots.append(.init(coordinate: camera, diameter: 30, fill: honestyColor,
                                      ringWidth: 2.5, label: "\(Int(pass.speedKmh.rounded()))",
                                      labelColor: .white))
        }
        return picture
    }

    /// Маркер этого проезда для развёрнутой карты. Один проезд — значит
    /// `times` = 1, а «с превышением» решаем той же штрафной ступенью, что и
    /// чип статуса: два разных ответа об одном проезде на двух экранах — это
    /// баг, а не оформление.
    private var fullMapMarker: PassMarker? {
        guard let coordinate = pass.coordinate else { return nil }
        let verdict = pass.verdict
        return PassMarker(cameraID: pass.cameraID, lat: coordinate.latitude,
                          lon: coordinate.longitude,
                          location: pass.location.isEmpty ? pass.kind.displayName : pass.location,
                          times: 1, overTimes: verdict == .over ? 1 : 0,
                          maxSpeedKmh: pass.speedKmh, limitKmh: pass.limitKmh,
                          edgeTimes: verdict == .edge ? 1 : 0)
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
                CameraIcon(kind: pass.kind, side: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pass.location.isEmpty ? pass.kind.displayName : pass.location)
                        .font(.rounded(19, .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text("\(pass.kind.displayName) · \(Formatting.dateAndClock(pass.date))")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }

            // Скорость живёт в ПАНЕЛИ СОСТОЯНИЯ, а не строкой среди серых
            // соседей: покрашен целый блок, и ответ виден боковым зрением.
            // Разделителя перед ней больше нет — панель отделяет себя сама.
            HStack(spacing: 14) {
                if let limit = pass.limitKmh {
                    SpeedLimitSign(limit: limit, diameter: 50)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("ваша скорость")
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                    // Герой карточки: ради этого числа экран и открывают.
                    // Цвет состояния — у самой цифры; цветное свечение вокруг
                    // убрано вместе с остальными «ореолами» (31D).
                    // Десятые у границы вердикта (PassVerdict.speedText).
                    Text(String(format: String(localized: "%@ км/ч"),
                                PassVerdict.speedText(speedKmh: pass.speedKmh, limitKmh: pass.limitKmh)))
                        .font(.numeral(30, .heavy).monospacedDigit())
                        .foregroundStyle(honestyColor)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    // Вердикт — под числом, а не справа: в ряд со знаком и
                    // крупной скоростью он не помещался, и обрезалось то одно,
                    // то другое («превы / шение», «88 к…»).
                    statusChip
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .statePanel(honestyColor)

            // «На грани» словами: штрафа нет, а балл снят — и сколько до штрафа.
            if pass.verdict == .edge, let over = overKmh,
               let shown = PassVerdict.excessText(speedKmh: pass.speedKmh, limitKmh: pass.limitKmh) {
                Text(edgeExplanation(over: over, shown: shown))
                    .font(.rounded(13, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    /// «+5 км/ч: штрафа обычно нет, но балл снят — ещё +1 км/ч, и это штраф.»
    /// `over` — точное превышение (по нему судят), `shown` — оно же на экране.
    private func edgeExplanation(over: Double, shown: String) -> String {
        let toFine = max(1, Int(FineSchedule.toleranceKmh - over) + 1)
        return String(format: String(localized: "+%1$@ км/ч: штрафа обычно нет, но балл снят — ещё +%2$lld км/ч, и это штраф."),
                      shown, toFine)
    }

    @ViewBuilder private var statusChip: some View {
        let fine = overKmh.map { FineSchedule.fine(overKmh: $0) } ?? 0
        if pass.verdict == .edge {
            // Третье состояние (аудит 05.11): зелёное «в лимите» при снятом
            // балле было неправдой, красное «превышение» — тоже.
            Label(PassVerdict.edge.word, systemImage: PassVerdict.edge.symbol)
                .font(.rounded(15, .bold))
                .foregroundStyle(PassVerdict.edge.tint)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.quietFill,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if fine > 0 {
            // «+28 км/ч» со знаком опасности: что это превышение, говорит
            // красная панель; слово «превышение» рядом с крупной скоростью
            // ломалось посередине — «превы / шение».
            Group {
                if let shown = PassVerdict.excessText(speedKmh: pass.speedKmh, limitKmh: pass.limitKmh) {
                    Label(String(format: String(localized: "+%@ км/ч"), shown),
                          systemImage: "exclamationmark.triangle.fill")
                } else {
                    Label("превышение", systemImage: "exclamationmark.triangle.fill")
                }
            }
            .font(.rounded(15, .bold))
            .foregroundStyle(Theme.danger)
            .lineLimit(1)
            .fixedSize()
            .accessibilityLabel(Text(String(format: String(localized: "превышение на %@ км/ч"),
                                            PassVerdict.excessText(speedKmh: pass.speedKmh,
                                                                   limitKmh: pass.limitKmh) ?? "0")))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.quietFill,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else if pass.limitKmh != nil {
            Label("в лимите", systemImage: "checkmark.shield.fill")
                .font(.rounded(15, .bold))
                .foregroundStyle(Theme.success)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.quietFill,
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
                            // Внесённое постановление — его сумма, а не оценка.
                            value: pass.fineAmount.map { FineFormat.money($0) } ?? Formatting.money(fine))
                    if pass.fineReceiptID != nil {
                        // Сверен с постановлением (этап 17): судьбу правит
                        // экран «Штрафы» — там же сумма, срок и оплата.
                        Label("Постановление внесено — в «Штрафах»", systemImage: "doc.text")
                            .font(.rounded(13, .medium))
                            .foregroundStyle(Theme.textSecondary)
                    } else if record != nil {
                        // Судьба штрафа отмечается и отсюда: человек смотрит на
                        // конкретный проезд — незачем гонять его в общий список.
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
                if !costsPoints { whatIfCard }
                methodCard
                if pass.silent != true { missedAlertCard }
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
        case .pending:   return String(localized: "Штраф ≈ (оценка)")
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
            withMotion(Motion.standard) {
                env.trip.setFineOutcome(outcome, passID: pass.id, tripID: record.id)
                fineOutcome = outcome
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.rounded(15, .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 12).padding(.vertical, 8)
                // Нейтральная капсула с кромкой: нажимаемый предмет, а не
                // подкрашенный прямоугольник; цвет — у текста и значка (31D).
                .background(Theme.quietFill, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 1))
                // Капсула ~36 pt на глаз прежняя, мишень — 44 pt.
                .tapTarget()
        }
        .buttonStyle(PressableStyle())
    }

    private func costRow(icon: String, tint: Color, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.rounded(15, .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(Theme.quietFill, in: Circle())
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
                .font(.numeral(19, .heavy).monospacedDigit())
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
                    // Строка 14 pt — ~18 pt мишени, а это и есть та самая
                    // жалоба, ради которой карточка существует.
                    .tapTarget()
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
