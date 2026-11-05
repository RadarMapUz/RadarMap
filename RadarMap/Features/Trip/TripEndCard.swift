//
//  TripEndCard.swift
//  RadarMap
//
//  «Поездка сохранена» — итог сразу после стопа.
//
//  Цифры поездки интереснее всего в момент, когда заглушён двигатель, — а
//  приложение молчало: итог был виден, только если самому открыть Итоги.
//  Если новая запись похожа на продолжение предыдущей (заехал в магазин, по
//  привычке нажал «Завершить») — склейка предлагается прямо здесь.
//
//  Облик — «путь + балл» (этап 45, вариант A, выбор владельца 05.11): снимок
//  своего пути с камерами (картинка, не живая карта), крупный балл, «12,4 км ·
//  18 мин» и не больше двух строк заработанного (TripReward): о вождении — «Все
//  8 камер — без превышения» или факт превышения без похвалы, о сообществе —
//  подтверждения своей отметки. Вся шапка — вход в подробности.
//
//  Показывается только на переднем плане и только для свежесохранённой
//  записи (см. MapScreen.maybeShowTripEnd): автозавершение в кармане
//  обслуживает уведомление, а не карточка поверх карты, которую никто не видит.
//
//  Если приложение промолчало о камере, мимо которой проехали, — строка
//  «Промолчала о камере» с кнопкой «Не предупредила» (12.5): та же жалоба,
//  что на экране проезда, только в одно касание и в момент, когда водитель
//  ещё помнит, как это было (MissedAlertPrompt).
//

import CoreLocation
import SwiftUI

struct TripEndCard: View {
    @Environment(AppEnvironment.self) private var env
    let record: TripRecord
    var onDetail: (TripRecord) -> Void
    var onMerged: () -> Void
    var onDismiss: () -> Void

    @State private var shareSubject: ShareSubjectBox?
    @State private var confirmsMerge = false
    /// Проезды, о тишине которых уже сказали (12.5). В памяти карточки:
    /// она живёт до закрытия, а отправленное ушло на сервер.
    @State private var reportedMissed: Set<UUID> = []
    @State private var isSendingMissed = false
    /// Сколько подтверждений прежних отметок показали прошлым итогом — с
    /// первого появления карточки (TripReward.earlierConfirmed).
    @State private var seenConfirmations: Int?
    @State private var baselineRead = false
    /// Ширина карточки: на SE снимок пути ниже.
    @State private var width: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            if record.hasTrack {
                picture
            }
            header
            ForEach(Array(rewardLines.enumerated()), id: \.offset) { _, line in
                rewardRow(line)
            }
            if let previous = mergeCandidate {
                mergeRow(previous: previous)
            }
            missedAlertRow
            reportsRow
        }
        .padding(12)
        .liftedBackground(Theme.surface, in: shape)
        .overlay(shape.strokeBorder(Theme.edgePanel, lineWidth: 1))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .sheet(item: $shareSubject) { box in
            SharePreviewSheet(subject: box.subject)
        }
        .confirmationDialog("Объединить с предыдущей поездкой?",
                            isPresented: $confirmsMerge, titleVisibility: .visible) {
            Button("Объединить") { merge() }
            Button("Отмена", role: .cancel) {}
        }
        // Подтверждения своих отметок — если пора спросить (раз в окно, не
        // на каждом показе); отметка этой поездки обычно ещё без голосов.
        .task { await env.mobile.refreshImpactIfDue() }
        // Отсчёт «новых подтверждений» — всё, что этот итог уже показал.
        .onChange(of: env.mobile.impactRevision, initial: true) { _, _ in rememberConfirmations() }
    }

    // MARK: - Путь

    /// Снимок пути с камерами — картинка, не живая карта (правило: без живой
    /// карты поверх живой карты и в прокрутке). На SE ниже: карточка вместе
    /// с доком не должна закрыть больше половины экрана.
    private var picture: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
        return MapPictureView(key: "tripend|\(record.id)|\(record.passed.count)",
                              picture: Self.picture(record),
                              height: width > 0 && width < AppConfig.tripEndCompactWidth ? 96 : 120)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.stroke, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 0) {
                    shareButton
                    closeButton
                }
            }
            .accessibilityElement(children: .contain)
    }

    /// Трек цветом маршрута; камера в лимите — зелёная точка с галочкой,
    /// превышение — крупная, со скоростью, поверх всего; без лимита — серая.
    static func picture(_ record: TripRecord) -> MapPicture {
        var picture = MapPicture()
        let points = record.trackPoints
        picture.lines = [.init(coordinates: points.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
        }, color: Theme.route, width: 4, casing: Theme.routeCasing, casingWidth: 7)]
        var over: [MapPicture.Dot] = []
        for pass in record.passed {
            guard let coordinate = pass.coordinate else { continue }
            if let limit = pass.limitKmh {
                if pass.speedKmh <= Double(limit) {
                    picture.dots.append(.init(coordinate: coordinate, diameter: 16, fill: Theme.success,
                                              ringWidth: 1.5, label: "✓", labelColor: .white))
                } else {
                    over.append(.init(coordinate: coordinate, diameter: 22,
                                      fill: PassStyle.color(speed: pass.speedKmh, limit: limit),
                                      ringWidth: 2, label: "\(Int(pass.speedKmh.rounded()))",
                                      labelColor: Theme.background))
                }
            } else {
                picture.dots.append(.init(coordinate: coordinate, diameter: 9, fill: Theme.textTertiary))
            }
        }
        if let start = points.first, let finish = points.last {
            picture.dots += TripEndpoints.dots(
                start: CLLocationCoordinate2D(latitude: start.lat, longitude: start.lon),
                finish: CLLocationCoordinate2D(latitude: finish.lat, longitude: finish.lon))
        }
        picture.dots += over
        return picture
    }

    // MARK: - Балл и путь словами

    private var header: some View {
        HStack(spacing: 12) {
            Button { onDetail(record) } label: {
                HStack(spacing: 12) {
                    heroScore
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Поездка сохранена")
                            .font(.rounded(12, .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        Text(verbatim: factsLine)
                            .font(.rounded(15, .bold).monospacedDigit())
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
            .buttonStyle(PressableStyle(.card))
            .accessibilityHint(Text("Подробнее"))
            // Без снимка (короткая поездка без трека) крестик и «поделиться» — здесь.
            if !record.hasTrack {
                VStack(spacing: 0) {
                    closeButton
                    shareButton
                }
            }
        }
    }

    private var closeButton: some View {
        roundButton("xmark", tint: Theme.textSecondary, touch: .cancel) {
            // Сказали — счётчик протухших отметок в ноль.
            env.mobile.acknowledgeUndelivered()
            onDismiss()
        }
        .accessibilityLabel(Text("Скрыть итог поездки"))
    }

    private var shareButton: some View {
        roundButton("square.and.arrow.up", tint: Theme.accent, action: share)
            .accessibilityLabel(Text("Поделиться поездкой"))
    }

    /// «12,4 км · 18 мин» — камеры сказаны строкой заработанного и точками
    /// на снимке.
    private var factsLine: String {
        [Formatting.distance(record.distanceMeters),
         Formatting.duration(record.movingDuration)].joined(separator: " · ")
    }

    /// Крестик и «поделиться» — малые круги 30 pt, мишень 44.
    private func roundButton(_ symbol: String, tint: Color, touch: TouchRole = .regular,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.rounded(12, .bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Theme.surface, in: Circle())
                .overlay(Circle().strokeBorder(Theme.stroke, lineWidth: 1))
                .tapTarget()
        }
        .buttonStyle(PressableStyle(touch))
    }

    private func share() {
        Task {
            let map = await TripMapSnapshot.render(track: record.trackPoints,
                                                   passes: record.passed,
                                                   size: CGSize(width: 1032, height: 840))
            shareSubject = ShareSubjectBox(subject: .trip(record, map: map))
        }
    }

    // MARK: - Балл

    /// Балл крупно, без кольца: число и есть итог, а его цвет (Theme.score —
    /// тот же, что в Итогах и на карточке «поделиться») говорит «хорошо /
    /// плохо». Без балла — печать вердикта на той же плашке.
    @ViewBuilder private var heroScore: some View {
        if let score = record.score.map({ Int($0) }) {
            VStack(spacing: -2) {
                Text(verbatim: "\(score)")
                    .font(.numeral(46, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.score(score))
                    .minimumScaleFactor(0.7)
                Text("рейтинг")
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 76, height: 72)
            .background(Theme.quietFill, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(String(format: String(localized: "Балл поездки: %lld"), score)))
        } else {
            let clean = record.verdict == .clean
            Image(systemName: clean ? "checkmark.seal.fill" : "checkmark.circle.fill")
                .font(.rounded(30, .bold))
                .foregroundStyle(clean ? Theme.success : Theme.accent)
                .frame(width: 76, height: 72)
                .background(Theme.quietFill, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        }
    }

    // MARK: - Заработанное (TripReward)

    /// Свои отметки — то, что телефон помнит о них (MobileCameraService.mine).
    private var ownReports: [TripReward.OwnReport] {
        env.mobile.mine.compactMap { mine in
            ReportKind(rawValue: mine.kind).map {
                TripReward.OwnReport(kind: $0, at: mine.at, confirmers: mine.confirmers, confirmed: mine.confirmed)
            }
        }
    }

    /// Не больше двух строк: о вождении и о сообществе.
    private var rewardLines: [TripReward.Line] {
        // Подписка на «пришли подтверждения»: `mine` вне наблюдения.
        _ = env.mobile.impactRevision
        return TripReward.pick(verdict: record.verdict,
                               passes: record.passed.map { TripReward.Pass(speedKmh: $0.speedKmh, limitKmh: $0.limitKmh) },
                               tripStart: record.startedAt, tripEnd: record.endedAt,
                               reports: ownReports, seenConfirmations: seenConfirmations)
    }

    /// Запомнить, сколько подтверждений уже показано: следующий итог скажет
    /// только о новых. Прежнее число читается один раз — до первой записи.
    private func rememberConfirmations() {
        if !baselineRead {
            seenConfirmations = Storage.intIfPresent(.tripRewardSeenConfirmations)
            baselineRead = true
        }
        Storage.set(TripReward.earlierConfirmations(ownReports, before: .distantFuture),
                    for: .tripRewardSeenConfirmations)
    }

    private func rewardRow(_ line: TripReward.Line) -> some View {
        let face = rewardFace(line)
        return HStack(spacing: 10) {
            Image(systemName: face.symbol)
                .font(.rounded(14, .bold))
                .foregroundStyle(face.tint)
                .frame(width: 30, height: 30)
                .background(Theme.quietFill, in: Circle())
                .accessibilityHidden(true)
            Text(verbatim: face.text)
                .font(.rounded(15, .semibold))
                .foregroundStyle(face.textTint)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Факт превышения — цветом балла, без похвалы; похвала — спокойным
    /// текстом с зелёным значком.
    private func rewardFace(_ line: TripReward.Line) -> (symbol: String, tint: Color, text: String, textTint: Color) {
        let factTint = record.score.map { Theme.score(Int($0)) } ?? Theme.danger
        switch line {
        case .camerasClean(let clean, let total):
            let text: String
            if clean == total {
                text = total == 1 ? String(localized: "Камера — без превышения")
                                  : String(localized: "Все \(total) камер — без превышения")
            } else {
                text = String(format: String(localized: "Камеры без превышения: %1$lld из %2$lld"), clean, total)
            }
            return ("checkmark.circle.fill", Theme.success, text, Theme.textPrimary)
        case .risk(let amount):
            return ("exclamationmark.triangle.fill", factTint,
                    String(format: String(localized: "риск ≈ %@"), Formatting.money(amount)), factTint)
        case .overspeed(let count):
            return ("exclamationmark.triangle.fill", factTint,
                    String(format: String(localized: "Штрафуемых превышений: %lld"), count), factTint)
        case .reportConfirmed(let drivers):
            return ("person.2.fill", Theme.success,
                    String(localized: "Вашу отметку подтвердили \(drivers) водителей"), Theme.textPrimary)
        case .reportAwaiting(let kind):
            return ("clock", Theme.textSecondary,
                    String(format: String(localized: "%@ — скажу, когда подтвердят"), ReportWords.marked(kind)),
                    Theme.textPrimary)
        case .earlierConfirmed(let count):
            return ("person.2.fill", Theme.success,
                    String(format: String(localized: "С прошлой поездки — новых подтверждений ваших отметок: %lld"),
                           count),
                    Theme.textPrimary)
        }
    }

    // MARK: - Склейка «это продолжение прошлой»

    /// Предыдущая запись, если свежая выглядит её продолжением. Считается по
    /// тем же правилам, что карточка в Итогах, — здесь просто раньше по времени.
    private var mergeCandidate: TripRecord? {
        let history = env.trip.history
        guard history.count >= 2, history[0].id == record.id else { return nil }
        let previous = history[1]
        guard TripMerge.suggestsMerge(previous: previous, next: record,
                                      savedPlaces: env.settings.savedPlaceCoordinates)
        else { return nil }
        return previous
    }

    /// Склейка — через подтверждение. Строка стоит вплотную над «Подробнее»,
    /// и тап, промахнувшийся на пару пунктов, молча сливал две поездки в одну:
    /// карточка тут же подменялась склеенной записью, а вернуть всё назад
    /// можно было только разделением в деталке.
    private func mergeRow(previous: TripRecord) -> some View {
        Button {
            confirmsMerge = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.rounded(15, .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Theme.quietFill, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Похоже, это продолжение прошлой")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(String(format: String(localized: "Объединить с поездкой в %@"),
                                Formatting.clock(previous.startedAt)))
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.rounded(11, .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(10)
            .background(Theme.quietFill,
                        in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - Свои отметки без сети

    /// «Отправлю позже» — обещание, и итог поездки говорит, чем оно кончилось:
    /// отметка протухла без связи или ещё ждёт её. Молча пропадать она не
    /// должна — водитель на обещание рассчитывал и второй раз не отметил.
    @ViewBuilder private var reportsRow: some View {
        let lost = env.mobile.undeliveredCount
        let waiting = env.mobile.pendingCount
        if lost > 0 || waiting > 0 {
            HStack(spacing: 10) {
                Image(systemName: lost > 0 ? "antenna.radiowaves.left.and.right.slash" : "clock.arrow.circlepath")
                    .font(.rounded(14, .bold))
                    .foregroundStyle(lost > 0 ? Theme.warning : Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Theme.background, in: Circle())
                Text(verbatim: lost > 0
                     ? String(format: String(localized: "Не ушло отметок: %lld — связи не было"), lost)
                     : String(format: String(localized: "Ждут связи: %lld — отправлю, когда появится"), waiting))
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Theme.quietFill,
                        in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - «Не предупредила» (12.5)

    /// Промолчали о камерах этой поездки — строка с одной кнопкой; после
    /// отправки — «Спасибо — разберёмся», пока карточка на экране.
    @ViewBuilder private var missedAlertRow: some View {
        let missed = MissedAlertPrompt.candidates(passes: record.passed, reported: reportedMissed)
        if !missed.isEmpty || !reportedMissed.isEmpty {
            // Две строки, а не одна: на SE заголовок и кнопка в одну строку
            // обрезались оба («Промолчала о ка…», «Не преду…»).
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: missed.isEmpty ? "checkmark.circle.fill" : "speaker.slash.fill")
                        .font(.rounded(14, .bold))
                        .foregroundStyle(missed.isEmpty ? Theme.success : Theme.warning)
                        .frame(width: 30, height: 30)
                        .background(Theme.background, in: Circle())
                    if missed.isEmpty {
                        Text("Спасибо — разберёмся")
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: MissedAlertPrompt.title(count: missed.count))
                                .font(.rounded(15, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if missed.count == 1, let first = missed.first {
                                Text(verbatim: first.location.isEmpty ? first.kind.displayName : first.location)
                                    .font(.rounded(11))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                if !missed.isEmpty {
                    Button { sendMissed(missed) } label: {
                        Group {
                            if isSendingMissed {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Не предупредила", systemImage: "exclamationmark.bubble.fill")
                                    .font(.rounded(15, .semibold))
                                    .foregroundStyle(Theme.warning)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: Theme.controlSize)
                        .background(Theme.background,
                                    in: RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(isSendingMissed)
                    .accessibilityHint(Text("Отправит место, скорость и лимит этого проезда"))
                }
            }
            .padding(10)
            .background(Theme.quietFill,
                        in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .transition(.opacity)
        }
    }

    /// Одно касание — жалоба на каждый проезд, о котором промолчали: у
    /// каждого своё место и скорость, разбирать их по одному. Отправка та
    /// же, что на экране проезда; очередь без сети — тоже успех.
    private func sendMissed(_ passes: [PassedCamera]) {
        guard !isSendingMissed else { return }
        isSendingMissed = true
        let dbVersion = env.cameras.dbVersion
        Task {
            for pass in passes {
                _ = await env.feedback.reportMissedAlert(pass: pass, dbVersion: dbVersion)
            }
            isSendingMissed = false
            withMotion(Motion.standard) { reportedMissed.formUnion(passes.map(\.id)) }
        }
    }

    private func merge() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withMotion(Motion.standard) {
            env.trip.mergeWithPrevious(id: record.id)
            onMerged()
        }
    }
}
