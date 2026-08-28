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

    /// Версия и номер сборки: первое, что спрашивают в ответ на письмо.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
    @Environment(\.dismiss) private var dismiss
    @State private var assignSlot: PlaceSlot?
    @State private var showFeedback = false
    @State private var showLanguageRestart = false

    var body: some View {
        @Bindable var settings = env.settings

        NavigationStack {
            Form {
                Section {
                    Toggle("Звук", isOn: $settings.soundEnabled)
                    if settings.soundEnabled {
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.fill").foregroundStyle(Theme.textSecondary)
                            Slider(value: $settings.alertVolume, in: 0.2...1.0).tint(Theme.accent)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(Theme.textSecondary)
                        }
                        // Ползунок без прослушивания — это гадание: громкость
                        // оповещения зависит и от него, и от системного звука,
                        // и от того, играет ли музыка. Проверять это на дороге,
                        // когда камера уже рядом, поздно.
                        Button {
                            env.alerts.beep(count: 1)
                            env.alerts.speak(String(localized: "Камера, триста метров"))
                        } label: {
                            Label("Прослушать оповещение", systemImage: "play.circle.fill")
                                .font(.rounded(14, .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Toggle("Вибрация у камер", isOn: $settings.hapticsEnabled)
                    // Один профиль вместо четырёх перечислений. Раньше поведение
                    // задавали голос, режим город/трасса, фоновые баннеры и старт
                    // поездки, и в трёх из них было своё «Авто»/«Умно» с разным
                    // смыслом — предсказать комбинацию было нельзя.
                    Picker("Профиль", selection: $settings.alertProfile) {
                        ForEach(AlertProfile.allCases) { Text($0.title).tag($0) }
                    }
                    Text(settings.alertProfile.detail)
                        .font(.rounded(11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    // «Свой» — для тех, кто хочет разобрать поведение по частям.
                    if settings.alertProfile == .custom {
                        Picker("Голос о камерах", selection: $settings.voiceMode) {
                            ForEach(VoiceMode.allCases) { Text($0.title).tag($0) }
                        }
                        Text(settings.voiceMode.detail)
                            .font(.rounded(11))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Picker("Город или трасса", selection: $settings.alertMode) {
                            ForEach(AlertMode.allCases) { Text($0.title).tag($0) }
                        }
                    }

                    // Голос о САМОМ превышении — отдельно от голоса о камерах:
                    // просьба из реальной поездки — фраза без камеры впереди
                    // воспринимается как ворчание, штраф-то возможен у камеры.
                    Picker("Голос о превышении", selection: $settings.overspeedVoice) {
                        ForEach(OverspeedVoice.allCases) { Text($0.title).tag($0) }
                    }
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
                    Text("Звук и вибрация предупреждают о камере всегда — голос отдельно. «Авто» сам различает город и трассу: в городе короткая фраза, на трассе полная, при превышении — громко и с лимитом. О камерах, которые вы проезжаете каждый день спокойно, приложение молчит и только отмечает вибрацией — но заговорит, если подъезжаете к ним с превышением. «Голос о превышении» — про фразу без камеры: «У камер» скажет о превышении только когда впереди по вашей дороге камера, в остальное время превышение видно цветом скорости.")
                        .fixedSize(horizontal: false, vertical: true)
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
                        .fixedSize(horizontal: false, vertical: true)
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
                } header: {
                    Text("Скорость")
                } footer: {
                    Text("Знак лимита дороги на панели и голос при превышении. Допуск — на сколько можно превысить, прежде чем приложение сочтёт это превышением.")
                        .fixedSize(horizontal: false, vertical: true)
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
                    Text("«Авто» — светлая подложка днём (тёмная на солнце бликует), ночью всегда тёмная. Интерфейс остаётся тёмным.\n\nЧем рисовать карту — Apple, своя схема или движок — выбирается кнопкой слоёв на самой карте: там виден результат, и переключение действует сразу.")
                        .fixedSize(horizontal: false, vertical: true)
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
                    Toggle("Спидометр при старте поездки", isOn: $settings.dashboardAutoOpens)
                } footer: {
                    Text("«Умный» — поездка включается сама только в вашей машине (CarPlay или знакомая магнитола), в чужой сначала спросит «вы за рулём?». «Авто» — всегда сама. «Ручной» — только кнопкой, слежение за движением выключено совсем. Заезд по пути (магазин, заправка) в новую поездку не превращается — остаётся остановкой внутри той же. Экран в поездке не засыпает, как у навигаторов. Спидометр — самый экономный экран: чёрный фон и схема вместо карты; закрыли его руками — до конца поездки не откроется сам.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Toggle("Голосовая навигация", isOn: $settings.turnByTurnVoice)
                    Toggle("Варианты маршрута", isOn: $settings.routeAlternatives)
                    Toggle("Следующая камера в панели", isOn: $settings.showNextCamera)
                } header: {
                    Text("Маршрут")
                } footer: {
                    Text("Подсказки манёвров «через 300 м направо» и выбор из нескольких вариантов при построении. Панель маршрута может показывать ближайшую камеру по курсу.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Toggle("Адаптивный GPS", isOn: $settings.adaptiveGPS)
                        .onChange(of: settings.adaptiveGPS) { _, _ in
                            // Иначе выключение в поездке залипало бы на последнем тире.
                            env.location.refreshLocationMode()
                        }
                } header: {
                    Text("Батарея")
                } footer: {
                    Text("Вдали от камер и манёвров точность GPS снижается, у самой камеры возвращается к максимальной. Выключать стоит, только если кажется, что оповещения запаздывают.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Что приложение выучивает само. Обе вещи меняют поведение
                // молча (камера перестала называться вслух, на экране появилась
                // подсказка «Домой»), поэтому им нужен и тумблер, и объяснение:
                // необъяснённая догадка читается как сбой.
                Section {
                    Toggle("Умная тишина у знакомых камер", isOn: $settings.smartSilence)
                        .onChange(of: settings.smartSilence) { _, _ in
                            env.location.refreshFamiliarCameras()
                        }
                    Toggle("Подсказка «Домой» и «На работу»", isOn: $settings.destinationSuggestions)
                        .onChange(of: settings.destinationSuggestions) { _, _ in
                            env.refreshLearnedPlaces()
                        }
                    // Выключенная настройка не должна оставлять данные лежать:
                    // человек выключил подсказки — значит и списку мест на
                    // диске взяться неоткуда.
                    Toggle("Подсказки о треногах по памяти", isOn: $settings.tripodHints)
                        .onChange(of: settings.tripodHints) { _, enabled in
                            if enabled {
                                Task { await env.hotspots.refresh() }
                            } else {
                                env.hotspots.clear()
                            }
                        }
                } header: {
                    Text("Приложение учится")
                } footer: {
                    Text("Камеру, которую вы проезжаете шесть и больше раз за месяц и ни разу с превышением, приложение перестаёт называть вслух: на карте у неё галочка, в панели — «своя камера», предупреждение остаётся. Одно превышение — и она снова говорит; о передвижных радарах, треногах и ДТП голос звучит всегда. Дом и работа определяются по распорядку поездок — куда вы приезжаете вечером и куда утром буднего дня. Всё считается на телефоне и никуда не отправляется.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    ForEach(PlaceSlot.allCases) { slot in
                        placeRow(slot)
                    }
                } header: {
                    Text("Мои места")
                } footer: {
                    Text("Маршрут в один тап из «Поиска» — домой или на работу.")
                        .fixedSize(horizontal: false, vertical: true)
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
                    Toggle("Помогать улучшать приложение", isOn: $settings.usageStatsEnabled)
                } header: {
                    Text("Конфиденциальность")
                } footer: {
                    Text("Раз в сутки отправляем обезличенные счётчики: сколько поездок, километров и оповещений было. Ни маршрутов, ни координат, ни времени — только числа. Идентификатор меняется каждые 30 дней.")
                        .fixedSize(horizontal: false, vertical: true)
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
                        .fixedSize(horizontal: false, vertical: true)
                }

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


                // Страница проекта: что это, откуда данные, политика,
                // возможность помочь. Внутрь приложения платёжная кнопка не
                // ставится намеренно — App Review отдельно смотрит на ссылки,
                // уводящие на стороннюю оплату (Guideline 3.1.1). Здесь —
                // обычная ссылка на сайт проекта, а поддержка живёт на нём.
                Section {
                    Link(destination: AppConfig.projectPageURL) {
                        HStack {
                            Label("Страница проекта", systemImage: "safari.fill")
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.rounded(12, .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    HStack {
                        Label("Версия", systemImage: "number")
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(Self.appVersion)
                            .font(.rounded(14).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                } header: {
                    Text("О приложении")
                } footer: {
                    Text("Карты и ограничения скорости — © участники OpenStreetMap. Приложение бесплатное, без рекламы и без слежки.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .backport.scrollEdgeEffectStyle(.hard, for: .top)
            .onAppear { env.usage.noteScreen("settings") }
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
