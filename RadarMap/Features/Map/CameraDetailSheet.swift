//
//  CameraDetailSheet.swift
//  RadarMap
//
//  Попап камеры: тип, адрес, нарушения, кнопка «Открыть в Картах».
//

import SwiftUI
import MapKit
import UIKit

struct CameraDetailSheet: View {
    let camera: Camera
    var onRoute: (() -> Void)? = nil
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private enum ReportState: Equatable { case idle, sending, sent, queued }
    @State private var reportState: ReportState = .idle
    /// Догадка о направлении камеры по своим проездам. Считается в .task,
    /// а не в body: разбор истории — не работа для каждого кадра.
    @State private var aim: CameraAim.Verdict = .unknown
    @State private var aimPasses = 0
    /// Действие, ждущее второго касания. Всё, что заставляет камеру замолчать
    /// или стирает данные, — только через подтверждение: «Камеры больше нет»
    /// стояла в 8 pt от «Камера на месте», и промах навсегда выключал
    /// предупреждение о камере, которая стоит (вернуть её было нечем).
    @State private var confirmation: Confirmation?

    private enum Confirmation: Equatable {
        case gone, hide, deleteCustom, cancelMark(Int)

        var title: LocalizedStringKey {
            switch self {
            case .gone:         "Камеры больше нет?"
            case .hide:         "Скрыть камеру?"
            case .deleteCustom: "Удалить камеру?"
            case .cancelMark:   "Убрать отметку?"
            }
        }

        var message: LocalizedStringKey {
            switch self {
            case .gone:
                "Сообщим модератору. Пока он не проверит, камера продолжит предупреждать: если она всё-таки стоит, молчание обойдётся дороже лишнего сигнала."
            case .hide:
                "Скрытая камера не показывается и не предупреждает. Вернуть её можно в Настройках → База камер → Скрытые камеры."
            case .deleteCustom:
                "Своя камера исчезнет с карты и перестанет предупреждать."
            case .cancelMark:
                "Отметка исчезнет у всех водителей."
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if camera.isApproximate { approximateBanner }
                    addressBlock
                    aimBlock
                    // Действия — выше справки: на SE в детенте .medium список
                    // «Что умеет такой комплекс» уводил «Маршрут сюда» и
                    // жалобы под край, и шит открывался без единой кнопки.
                    // Возможности типа — справка, её можно и долистать.
                    routeButton
                    openInMapsButton
                    actionsBlock
                    violationsBlock
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.screenBackground)
            // String(id), не интерполяция Int: та форматирует с группировкой («№2,331»).
            .navigationTitle(String(format: String(localized: "Камера №%@"), String(camera.id)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
            .onAppear { env.usage.noteScreen("camera") }
        .presentationDragIndicator(.visible)
        .confirmationDialog(Text(confirmation?.title ?? ""),
                            isPresented: Binding(get: { confirmation != nil },
                                                 set: { if !$0 { confirmation = nil } }),
                            titleVisibility: .visible,
                            presenting: confirmation) { pending in
            confirmationActions(pending)
        } message: { pending in
            Text(pending.message)
        }
        .task {
            let passes = env.trip.history.flatMap(\.passed)
            aimPasses = passes.count { $0.cameraID == camera.id }
            aim = CameraAim.verdict(passes: passes, cameraID: camera.id, now: Date())
        }
    }

    /// Наблюдение о направлении — тем же тоном, что хотспоты треног: догадка
    /// говорит только тогда, когда уверена, и не притворяется фактом.
    ///
    /// На оповещения это не влияет НИКАК и влиять не будет: заглушить камеру
    /// можно лишь по доказательству, что она не наша, а поведение водителей —
    /// не доказательство (см. CameraAim).
    @ViewBuilder private var aimBlock: some View {
        if case .oneWay(let bearing) = aim {
            VStack(alignment: .leading, spacing: 6) {
                Label(String(format: String(localized: "Похоже, снимает едущих %@"),
                             CameraAim.cardinal(bearing)),
                      systemImage: "arrow.up.forward.circle.fill")
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.accent)
                Text(String(format: String(localized:
                    "Вывод по вашим %lld проездам: в эту сторону вы каждый раз сбрасываете скорость, во встречную — нет. Это наблюдение, а не данные реестра: предупреждать о камере мы продолжаем в обе стороны."),
                    aimPasses))
                    .font(.rounded(11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        }
    }

    // MARK: - Секции

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: camera.kind.symbolName)
                .font(.rounded(20, .bold))
                .foregroundStyle(camera.kind.glyphTint)
                .frame(width: 46, height: 46)
                .background(camera.kind.tint.gradient, in: Circle())
                .shadow(color: camera.kind.tint.opacity(0.6), radius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(camera.kind.displayName)
                    .font(.rounded(18, .bold))
                    .foregroundStyle(Theme.textPrimary)
                if let coordinate = env.location.currentCoordinate {
                    Text("в \(Formatting.distance(camera.distance(from: coordinate))) от вас")
                        .font(.rounded(13))
                        .foregroundStyle(Theme.accent)
                }
                // Бейдж доверия: сколько водителей подтвердило краудсорс-отметку.
                // Неподтверждённую не наряжаем в зелёное: точка на испытательном
                // сроке — и карточка честно говорит, что это пока слух.
                if let trust = env.mobile.confirmation(for: camera.id) {
                    if trust.confirmed {
                        Label(String(format: String(localized: "Подтвердили: %@ водит."),
                                     String(trust.upvotes + 1)),
                              systemImage: "person.2.fill")
                            .font(.rounded(12, .semibold))
                            .foregroundStyle(Theme.success)
                    } else {
                        Label(String(localized: "Ещё не подтверждена"),
                              systemImage: "questionmark.circle")
                            .font(.rounded(12, .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    // Возраст отметки — половина её ценности: тренога стоит
                    // час-полтора, и «10 минут назад» против «два часа назад»
                    // меняет решение водителя сильнее, чем число голосов.
                    // Старый сервер поля created не шлёт: там эпоха, и вместо
                    // возраста получилось бы «55 лет назад» — молчим.
                    if trust.created.timeIntervalSince1970 > 0 {
                        Text(trust.created.formatted(.relative(presentation: .named)))
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            // Лимит дороги, на которой стоит камера (данные OSM) — сразу видно,
            // сколько можно на этом участке.
            if let limit = env.speedLimits.limit(near: camera.coordinate) {
                SpeedLimitSign(limit: limit, diameter: 46)
            }
        }
    }

    private var addressBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !camera.location.isEmpty {
                Text(camera.location)
                    .font(.rounded(16, .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            Label(camera.subtitle, systemImage: "mappin.and.ellipse")
                .font(.rounded(14))
                .foregroundStyle(Theme.textSecondary)
            Text(String(format: "%.6f, %.6f", camera.lat, camera.lon))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .textSelection(.enabled)
        }
    }

    /// Что умеет комплекс ТАКОГО ТИПА — не что фиксирует именно эта камера.
    /// Реестр МВД содержит всего шесть полей (регион, район, место, тип и две
    /// координаты) и списка нарушений по камере в нём нет: он выводится из типа.
    /// Поэтому и заголовок, и галочки не должны выдавать наше предположение за
    /// проверенный факт — раньше блок назывался «Фиксирует нарушения» и у всех
    /// стационарных камер показывал один и тот же список из восьми пунктов.
    private var violationsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Что умеет такой комплекс")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)
            // На языке интерфейса (в базе — узбекская кириллица из egov).
            ForEach(camera.localizedViolations, id: \.self) { violation in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(camera.kind.tint)
                        .frame(width: 6, height: 6)
                        .padding(.top, 8)
                    Text(violation.capitalizedFirst)
                        .font(.rounded(15))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                }
            }
            Text("Список по каждой камере МВД не публикует — показываем возможности типа")
                .font(.rounded(11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
    }

    private var approximateBanner: some View {
        Label("Позиция уточняется: адрес из реестра не удалось привязать к дороге. Предупреждаем о такой камере с запасом.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.rounded(13))
            .foregroundStyle(Theme.warning)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
    }

    @ViewBuilder private var routeButton: some View {
        if let onRoute {
            PrimaryButton(title: "Маршрут сюда", systemImage: "arrow.triangle.turn.up.right.circle.fill") {
                dismiss()
                onRoute()
            }
        }
    }

    private var openInMapsButton: some View {
        // Второе действие — не жёлтое: две жёлтые подряд не говорят, какая главная.
        SecondaryButton(title: "Открыть в Картах", systemImage: "map.fill") {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: camera.coordinate))
            item.name = camera.displayTitle
            item.openInMaps()
        }
    }

    @ViewBuilder private var actionsBlock: some View {
        if env.mobile.isMobile(camera) {
            // Краудсорсинг: подтверждение продлевает жизнь отметки, «нет радара» — гасит.
            HStack(spacing: 12) {
                Button {
                    Task { await env.mobile.vote(cameraID: camera.id, stillThere: true) }
                    dismiss()
                } label: {
                    Label("Радар на месте", systemImage: "hand.thumbsup.fill")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.success)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.success.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                }
                Button {
                    Task { await env.mobile.vote(cameraID: camera.id, stillThere: false) }
                    dismiss()
                } label: {
                    Label("Уже нет", systemImage: "hand.thumbsdown.fill")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                }
            }
            // «Радар есть, но стоит не там» — третий, отдельный ответ. Раньше
            // его приходилось выражать через «Уже нет», то есть гасить точку
            // целиком: отметка в двухстах метрах от истины всё равно
            // предупреждает о засаде, и стирать её за неточность — потерять
            // предупреждение. Сервер считает этот голос обычным дизлайком по
            // сроку жизни, но показывает модератору отдельно, и тот двигает.
            Button {
                Task {
                    await env.mobile.vote(cameraID: camera.id, stillThere: false,
                                          origin: "misplaced")
                }
                dismiss()
            } label: {
                Label("Стоит не там", systemImage: "mappin.slash")
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.surface,
                                in: RoundedRectangle(cornerRadius: Theme.cornerMedium,
                                                     style: .continuous))
            }
            if let mine = env.mobile.cancellableReportID(),
               env.mobile.idOffsetApplied(mine) == camera.id {
                destructiveButton(title: "Убрать мою отметку", icon: "trash") {
                    confirmation = .cancelMark(mine)
                }
            }
        } else if env.cameras.isCustom(camera) {
            destructiveButton(title: "Удалить камеру", icon: "trash") {
                confirmation = .deleteCustom
            }
        } else {
            reportBlock
        }
    }

    // MARK: - Репорт об ошибке в базе

    /// Обратная связь по камере: репорт уходит на сервер (ручная модерация).
    /// «Камеры больше нет» сама камеру НЕ глушит: раньше жалоба сразу скрывала
    /// её у себя, то есть одно касание (или промах) выключало предупреждение
    /// до конца жизни приложения. Теперь заглушить можно только явно — второй
    /// кнопкой подтверждения, и вернуть — в Настройках.
    @ViewBuilder private var reportBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Что-то не так с этой камерой?")
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)

            switch reportState {
            case .sent, .queued:
                Label(reportState == .sent
                      ? "Спасибо! Проверим и обновим базу."
                      : "Спасибо! Отправим, когда появится связь.",
                      systemImage: "checkmark.circle.fill")
                    .font(.rounded(14, .semibold))
                    .foregroundStyle(Theme.success)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.success.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            case .sending:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Отправляем…")
                        .font(.rounded(14, .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            case .idle:
                HStack(spacing: 8) {
                    // Краудсорс в обе стороны: подтверждение «на месте» гасит ложные
                    // gone-репорты — база чистится голосами водителей, а не только жалобами.
                    reportButton(title: "Камера на месте", icon: "checkmark.seal.fill",
                                 tint: Theme.success) {
                        sendReport(.stillHere)
                    }
                    reportButton(title: "Камеры больше нет", icon: "camera.slash.fill",
                                 tint: Theme.warning) {
                        confirmation = .gone
                    }
                    reportButton(title: "Неверное место", icon: "mappin.slash.circle.fill",
                                 tint: Theme.warning) {
                        sendReport(.wrongLocation)
                    }
                }
                Button {
                    confirmation = .hide
                } label: {
                    Label("Просто скрыть на моей карте", systemImage: "eye.slash")
                        .font(.rounded(13, .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Theme.controlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .motionAnimation(Motion.standard, value: reportState)
    }

    /// Плитка репорта: фиксированная высота и две строки текста — три плитки в ряду
    /// всегда ровные, ничего не расползается.
    private func reportButton(title: LocalizedStringKey, icon: String, tint: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.rounded(18, .semibold))
                Text(title)
                    .font(.rounded(12, .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(height: 30)          // ровно две строки у всех плиток
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(tint.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        }
    }

    /// Кнопки подтверждения. Глушащее действие — `.destructive`, и у жалобы
    /// «нет камеры» оно второе, а первое — просто сообщить.
    @ViewBuilder private func confirmationActions(_ pending: Confirmation) -> some View {
        switch pending {
        case .gone:
            Button("Сообщить") { sendReport(.gone) }
            Button("Сообщить и не предупреждать", role: .destructive) {
                sendReport(.gone, hideLocally: true)
            }
        case .hide:
            Button("Скрыть", role: .destructive) {
                env.cameras.hide(camera)
                dismiss()
            }
        case .deleteCustom:
            Button("Удалить", role: .destructive) {
                env.cameras.deleteCustom(camera)   // revision → MapScreen обновит карту и мониторинг
                dismiss()
            }
        case .cancelMark(let id):
            Button("Убрать", role: .destructive) {
                Task { await env.mobile.cancelReport(id: id) }
                dismiss()
            }
        }
        Button("Отмена", role: .cancel) {}
    }

    private func sendReport(_ reason: CameraReportReason, hideLocally: Bool = false) {
        reportState = .sending
        Task {
            // Очередь никогда не теряет репорт: сервер недоступен → дошлём позже.
            let outcome = await env.feedback.reportCamera(camera, reason: reason,
                                                          dbVersion: env.cameras.dbVersion)
            reportState = outcome == .sent ? .sent : .queued
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // Только по явному выбору «и не предупреждать» — см. reportBlock.
            if hideLocally {
                env.cameras.hide(camera)
            }
            await Task.pause(seconds: 1.4)
            dismiss()
        }
    }

    private func destructiveButton(title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Label(title, systemImage: icon)
                .font(.rounded(15, .semibold))
                .foregroundStyle(Theme.danger)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
