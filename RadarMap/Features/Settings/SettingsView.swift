//
//  SettingsView.swift
//  RadarMap
//
//  Настройки: звук/голос, радиус оповещения, фильтр по типу.
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var assignSlot: PlaceSlot?
    @State private var showFeedback = false
    @State private var showLanguageRestart = false

    var body: some View {
        @Bindable var settings = env.settings

        NavigationStack {
            Form {
                Section {
                    Picker("Язык приложения", selection: $settings.appLanguage) {
                        ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: settings.appLanguage) { _, _ in
                        showLanguageRestart = true
                    }
                } header: {
                    Text("Язык")
                }

                Section {
                    Toggle("Звук", isOn: $settings.soundEnabled)
                    if settings.soundEnabled {
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.fill").foregroundStyle(Theme.textSecondary)
                            Slider(value: $settings.alertVolume, in: 0.2...1.0).tint(Theme.accent)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Toggle("Голосовое предупреждение", isOn: $settings.voiceEnabled)
                    Toggle("Вибрация у камер", isOn: $settings.hapticsEnabled)
                    Picker("Режим оповещений", selection: $settings.alertMode) {
                        ForEach(AlertMode.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Голос только при превышении", isOn: $settings.voiceOnlyWhenOverspeeding)
                    Picker("Баннеры в фоне", selection: $settings.backgroundAlerts) {
                        ForEach(BackgroundAlertMode.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Итоги недели по воскресеньям", isOn: $settings.weeklyDigest)
                        .onChange(of: settings.weeklyDigest) { _, enabled in
                            if !enabled { env.notifications.cancelWeeklyDigest() }
                        }
                } header: {
                    Text("Оповещения")
                } footer: {
                    Text("«Авто» сам различает город и трассу: в городе приложение говорит коротко («камера, 300 метров»), на трассе называет камеру полностью. Камеры, стоящие вплотную, объявляются одной фразой, а в пробке голос ждёт, пока вы поедете. Громче — только когда вы реально превышаете или впереди передвижной радар. «Голос только при превышении» — полная тишина, пока едете в лимите.")
                }

                Section {
                    Picker("Старт поездки", selection: $settings.tripStartMode) {
                        ForEach(TripStartMode.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: settings.tripStartMode) { _, _ in env.motion.syncEnabled() }
                    Toggle("Не гасить экран в поездке", isOn: $settings.keepScreenOn)
                        .onChange(of: settings.keepScreenOn) { _, keepOn in
                            if env.location.isTripActive {
                                UIApplication.shared.isIdleTimerDisabled = keepOn
                            }
                        }
                } footer: {
                    Text("«Умный» — поездка включается сама только в вашей машине (CarPlay или знакомая магнитола), в чужой сначала спросит «вы за рулём?». «Авто» — всегда сама. «Ручной» — только кнопкой, слежение за движением выключено совсем. Заезд по пути (магазин, заправка) в новую поездку не превращается — остаётся остановкой внутри той же. Экран в поездке не засыпает, как у навигаторов.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Радиус оповещения")
                            Spacer()
                            Text("\(Int(settings.alertRadius)) м")
                                .foregroundStyle(Theme.accent)
                                .font(.rounded(15, .semibold))
                        }
                        Slider(value: $settings.alertRadius, in: 200...1000, step: 50)
                            .tint(Theme.accent)
                            .onChange(of: settings.alertRadius) { _, _ in
                                env.location.refreshMonitoring()
                            }
                    }
                } header: {
                    Text("Дистанция")
                } footer: {
                    Text("За сколько метров до камеры предупреждать. Голос отсчитывает пороги по мере приближения.")
                }

                Section {
                    Toggle("Лимиты скорости", isOn: $settings.speedLimitsEnabled)
                    if settings.speedLimitsEnabled {
                        Picker("Допуск превышения", selection: $settings.overspeedTolerance) {
                            Text("0 км/ч").tag(0.0)
                            Text("+5 км/ч").tag(5.0)
                            Text("+10 км/ч").tag(10.0)
                            Text("+15 км/ч").tag(15.0)
                            Text("+20 км/ч").tag(20.0)
                        }
                    }
                    Toggle("Голосовая навигация", isOn: $settings.turnByTurnVoice)
                    Toggle("Варианты маршрута", isOn: $settings.routeAlternatives)
                    Toggle("Следующая камера в панели", isOn: $settings.showNextCamera)
                    Toggle("Адаптивный GPS (батарея)", isOn: $settings.adaptiveGPS)
                        .onChange(of: settings.adaptiveGPS) { _, _ in
                            // Иначе выключение в поездке залипало бы на последнем тире.
                            env.location.refreshLocationMode()
                        }
                } header: {
                    Text("Маршрут и скорость")
                } footer: {
                    Text("Знак лимита дороги и голос при превышении, подсказки манёвров «через 300 м направо», выбор из нескольких вариантов маршрута. Адаптивный GPS снижает точность вдали от камер — батарея живёт дольше.")
                }

                Section {
                    ForEach(PlaceSlot.allCases) { slot in
                        placeRow(slot)
                    }
                } header: {
                    Text("Мои места")
                } footer: {
                    Text("Маршрут в один тап из «Поиска» — домой или на работу.")
                }

                Section {
                    Picker("Тип камер", selection: $settings.filter) {
                        ForEach(CameraFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Тема карты", selection: $settings.mapAppearance) {
                        ForEach(MapAppearance.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Карта")
                } footer: {
                    Text("«Авто» — светлая подложка днём (тёмная на солнце бликует), ночью всегда тёмная. Интерфейс остаётся тёмным.")
                }

                Section {
                    LabeledContent("Версия базы", value: "v\(env.cameras.dbVersion)")
                    LabeledContent("Своих камер", value: "\(env.cameras.custom.count)")
                    if !env.cameras.hiddenIDs.isEmpty {
                        LabeledContent("Скрыто", value: "\(env.cameras.hiddenIDs.count)")
                    }
                    Button {
                        Task { await env.sync.check() }
                    } label: {
                        HStack {
                            Text("Проверить обновления")
                            Spacer()
                            syncStatusView
                        }
                    }
                    .disabled(env.sync.state == .checking || env.sync.state == .downloading)
                } header: {
                    Text("База камер")
                } footer: {
                    if let date = env.sync.lastCheckDate {
                        Text("Последняя проверка: \(date.formatted(date: .abbreviated, time: .shortened))")
                    }
                }

                Section {
                    Button {
                        showFeedback = true
                    } label: {
                        HStack {
                            Label("Написать разработчику", systemImage: "envelope.fill")
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.rounded(12, .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                } header: {
                    Text("Обратная связь")
                } footer: {
                    Text("Ошибки, идеи, неточные камеры — мы читаем каждое сообщение и правим базу.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .sheet(item: $assignSlot) { slot in
                SearchView(initialAssign: slot)
            }
            .sheet(isPresented: $showFeedback) {
                FeedbackFormView()
            }
            .alert("Язык изменён", isPresented: $showLanguageRestart) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Перезапустите приложение, чтобы язык применился полностью.")
            }
        }
    }

    private func placeRow(_ slot: PlaceSlot) -> some View {
        let place = env.settings.place(for: slot)
        return HStack(spacing: 12) {
            Image(systemName: slot.symbol)
                .foregroundStyle(place == nil ? Theme.textSecondary : Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.name)
                if let place {
                    Text(place.title)
                        .font(.rounded(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(place == nil ? String(localized: "Задать") : String(localized: "Изменить")) { assignSlot = slot }
                .font(.rounded(13, .semibold))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.borderless)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if place != nil {
                Button(role: .destructive) {
                    env.settings.setPlace(nil, for: slot)
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder private var syncStatusView: some View {
        switch env.sync.state {
        case .checking, .downloading:
            ProgressView().controlSize(.small)
        case .upToDate:
            Label("Актуальна", systemImage: "checkmark.circle.fill")
                .font(.rounded(13)).foregroundStyle(Theme.success).labelStyle(.titleAndIcon)
        case .updated:
            Label("Обновлено", systemImage: "arrow.down.circle.fill")
                .font(.rounded(13)).foregroundStyle(Theme.accent).labelStyle(.titleAndIcon)
        case .failed:
            Label("Ошибка сети", systemImage: "wifi.slash")
                .font(.rounded(13)).foregroundStyle(Theme.danger).labelStyle(.titleAndIcon)
        case .idle:
            EmptyView()
        }
    }
}
