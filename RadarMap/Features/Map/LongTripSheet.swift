//
//  LongTripSheet.swift
//  RadarMap
//
//  «Перед дальней дорогой» (12.4) — лист из панели маршрута длиннее 100 км,
//  до «Поехали»: карта областей по пути (что на телефоне, что докачать одной
//  кнопкой), камеры и посты по порядку с километром от старта, заправки
//  своего топлива по «Машине» с отклонением от дороги и самым длинным
//  отрезком без них.
//
//  Решения — в чистом LongTripBrief, данные — RouteCorridorService (только с
//  телефона: ни одного нового запроса о маршруте). Здесь разметка.
//
//  CarPlay этого листа нет — сознательно. В машине на вопросы этого листа
//  уже отвечают «Куда» → «Камеры впереди» (с постами) и плитки «АЗС»/«Метан»
//  (впереди по маршруту — заездом). Остальное здесь — решение на стоянке:
//  мегабайты и план заправок на 300 км, а длинный справочный список на
//  экране машины — ровно то, чего Developer Guide просит не делать.
//

import CoreLocation
import SwiftUI

struct LongTripSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    /// Показать камеру на карте.
    let onFocus: (Camera) -> Void
    /// Заехать на заправку по пути.
    let onPick: (Venue) -> Void

    @State private var report: RouteCorridorService.LongTrip?
    @State private var loading = true
    @State private var fuelKind: Venue.Kind?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    summary
                    LongTripMapSection(missingBytes: report?.missingBytes ?? 0)
                    // Заправки — до камер: короткий раздел, по которому решают
                    // до выезда, не должен прятаться за полусотней строк камер.
                    fuel.id(Anchor.fuel)
                    checkpoints.id(Anchor.cameras)
                    Section {
                    } footer: {
                        Text("Собрано на телефоне из уже скачанного — о маршруте сервер ничего нового не узнаёт.")
                            .font(.rounded(12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                #if DEBUG
                // Скриншот-хук `-longTripSection cameras|fuel`: прокрутить к разделу.
                .onChange(of: loading) { _, now in
                    let args = ProcessInfo.processInfo.arguments
                    guard !now, let i = args.firstIndex(of: "-longTripSection"), i + 1 < args.count,
                          let anchor = Anchor(rawValue: args[i + 1]) else { return }
                    Task {
                        await Task.pause(seconds: 0.5)
                        proxy.scrollTo(anchor, anchor: anchor == .download ? .center : .top)
                    }
                }
                #endif
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Перед дальней дорогой")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task(id: loadKey) {
            report = await env.corridor.brief(route: env.route, kinds: env.settings.vehicleEnergy.stops)
            loading = false
        }
    }

    /// Новый вариант, другая машина в настройках или докачанные файлы
    /// заведений — пересборка.
    private var loadKey: LoadKey {
        LoadKey(line: env.route.selected.map { ObjectIdentifier($0.polyline) },
                energy: env.settings.vehicleEnergy, cells: env.corridor.cellsRevision)
    }

    /// Разделы для скриншот-хука; `download` — кнопка карты (LongTripMapSection).
    enum Anchor: String { case cameras, fuel, download }

    private struct LoadKey: Equatable {
        let line: ObjectIdentifier?
        let energy: VehicleEnergy
        let cells: Int
    }

    // MARK: - Сводка

    private var summary: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: env.route.destinationName)
                    .font(.rounded(13, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                Text(verbatim: env.route.distanceText + " · " + env.route.etaText)
                    .font(.numeral(22, .heavy))
                    .foregroundStyle(Theme.textPrimary)
                if let tally = report?.brief.tally, !tally.isEmpty {
                    Text(verbatim: LongTripText.tally(tally))
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Theme.surface)
        }
    }

    // MARK: - Камеры и посты

    @ViewBuilder private var checkpoints: some View {
        Section {
            if loading {
                loadingRow
            } else if let brief = report?.brief {
                if brief.checkpoints.isEmpty {
                    note(String(localized: "Камер и постов по пути нет"))
                }
                ForEach(brief.checkpoints) { checkpointRow($0) }
            }
        } header: {
            header(String(localized: "Камеры и посты по порядку"))
        } footer: {
            if (report?.brief.tally.crowd ?? 0) > 0 {
                footer(String(localized: "Отметки водителей живут несколько часов — к этому месту их может уже не быть."))
            }
        }
    }

    private func checkpointRow(_ checkpoint: LongTripBrief.Checkpoint) -> some View {
        Button {
            onFocus(checkpoint.lead)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                kmLabel(checkpoint.along)
                CameraIcon(kind: checkpoint.lead.kind, side: 30, dashedRim: checkpoint.lead.isUnconfirmedMobile)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: LongTripText.title(checkpoint))
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !checkpoint.lead.displayTitle.isEmpty {
                        Text(verbatim: checkpoint.lead.displayTitle)
                            .font(.rounded(12))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Theme.controlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.surface)
        .listRowSeparatorTint(Theme.stroke)
        .accessibilityLabel(Text(verbatim: LongTripText.spoken(checkpoint)))
        .accessibilityHint(Text("Показать на карте"))
    }

    // MARK: - Заправки

    private var kinds: [Venue.Kind] { env.settings.vehicleEnergy.stops }

    private var shownKind: Venue.Kind? {
        fuelKind.flatMap { kinds.contains($0) ? $0 : nil } ?? kinds.first
    }

    @ViewBuilder private var fuel: some View {
        if let kind = shownKind {
            Section {
                if kinds.count > 1 { fuelChips }
                if loading {
                    loadingRow
                } else if let report, let plan = report.brief.fuel.first(where: { $0.kind == kind }) {
                    fuelPlan(plan, report: report)
                }
            } header: {
                header(LongTripText.fuelHeader(kind))
            } footer: {
                footer(String(format: String(localized: "Не дальше %@ от дороги"),
                              Formatting.distance(AppConfig.corridorVenueMeters)))
            }
        }
    }

    @ViewBuilder
    private func fuelPlan(_ plan: LongTripBrief.Fuel, report: RouteCorridorService.LongTrip) -> some View {
        let progress = env.route.progressAlong
        if let gap = plan.gap {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: plan.items.isEmpty ? LongTripText.none(plan.kind)
                     : LongTripText.gapTitle(plan.kind, meters: gap.meters))
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(plan.items.isEmpty ? Theme.warning : Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !plan.items.isEmpty {
                    Text(verbatim: LongTripText.gapDetail(gap, progress: progress,
                                                          routeLength: report.brief.routeLength))
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(Theme.surface)
            .accessibilityElement(children: .combine)
        } else {
            // Данных на весь путь нет — «дальше нет» не обещаем.
            note(report.missingCells > 0
                 ? String(localized: "Часть пути без данных о заправках — скачаются кнопкой выше")
                 : String(localized: "Для части пути данных о заправках пока нет — список может быть неполным"))
        }
        ForEach(plan.items.prefix(AppConfig.longTripFuelRows)) { venueRow($0) }
        if plan.items.count > AppConfig.longTripFuelRows {
            note(String(format: String(localized: "Ещё %@ дальше по пути"),
                        String(plan.items.count - AppConfig.longTripFuelRows)))
        }
    }

    private var fuelChips: some View {
        HStack(spacing: 8) {
            ForEach(kinds, id: \.self) { kind in
                let selected = kind == shownKind
                Button {
                    fuelKind = kind
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Text(verbatim: kind.title)
                        .font(.rounded(14, .semibold))
                        .foregroundStyle(selected ? Theme.onAccentFill : Theme.textPrimary)
                        .fixedSize()
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(selected ? AnyShapeStyle(Theme.accentFill) : AnyShapeStyle(Theme.background),
                                    in: Capsule())
                        .overlay(Capsule().stroke(selected ? .clear : Theme.stroke, lineWidth: 1))
                        .tapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .listRowBackground(Theme.surface)
    }

    private func venueRow(_ item: CorridorVenues.Item) -> some View {
        let venue = item.venue
        let station = venue.kind == .cng && env.cng.isActive ? env.cng.station(for: venue.point) : nil
        return Button {
            onPick(venue)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                kmLabel(item.along)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: venue.title)
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: LongTripText.venueDetail(item))
                        .font(.rounded(13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let station, let caption = CngRules.caption(station) {
                        Text(verbatim: caption)
                            .font(.rounded(12, .semibold))
                            .foregroundStyle(station.status == .nogas ? Theme.textTertiary : Theme.success)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "plus.circle.fill")
                    .font(.rounded(22))
                    .foregroundStyle(Theme.accent)
            }
            .frame(minHeight: Theme.controlSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.surface)
        .listRowSeparatorTint(Theme.stroke)
        .accessibilityLabel(Text(verbatim: LongTripText.spoken(item)))
        .accessibilityHint(Text("Заехать по пути"))
    }

    // MARK: - Общие куски

    /// Километр от старта — колонкой слева, по нему глаз идёт вдоль пути.
    private func kmLabel(_ along: CLLocationDistance) -> some View {
        Text(verbatim: LongTripText.km(along))
            .font(.rounded(14, .bold).monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 64, alignment: .leading)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var loadingRow: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Собираем по пути…")
                .font(.rounded(15))
                .foregroundStyle(Theme.textSecondary)
        }
        .listRowBackground(Theme.surface)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.rounded(14))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .listRowBackground(Theme.surface)
    }

    private func header(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.rounded(13, .semibold))
            .foregroundStyle(Theme.textSecondary)
            .textCase(nil)
    }

    private func footer(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.rounded(12))
            .foregroundStyle(Theme.textSecondary)
    }
}
