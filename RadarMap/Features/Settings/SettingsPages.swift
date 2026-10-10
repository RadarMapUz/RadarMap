//
//  SettingsPages.swift
//  RadarMap
//
//  Страницы разделов настроек (список разделов — SettingsView). Каждая —
//  одна тема; содержимое и поведение перенесены со старого общего экрана
//  без изменений.
//

import SwiftUI
import UIKit

// MARK: - Оповещения и звук

struct AlertSettingsPage: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
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
            } footer: {
                Text("Звук и вибрация предупреждают о камере всегда. Голос настраивается отдельно.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
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
            } header: {
                Text("Голос")
            } footer: {
                SettingsFootnote([
                    "«Авто» различает город и трассу: в городе короткая фраза, на трассе полная, при превышении — громче и с лимитом.",
                    "О камерах, которые вы каждый день проезжаете спокойно, приложение молчит и только отмечает вибрацией. Подъедете с превышением — заговорит.",
                    "«Голос о превышении» — про фразу без камеры. В режиме «У камер» она звучит, только когда камера впереди по вашей дороге; в остальное время превышение видно цветом скорости.",
                ])
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
                Picker("Баннеры в фоне", selection: $settings.backgroundAlerts) {
                    ForEach(BackgroundAlertMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Итоги недели по воскресеньям", isOn: $settings.weeklyDigest)
                    .onChange(of: settings.weeklyDigest) { _, enabled in
                        if !enabled { env.notifications.cancelWeeklyDigest() }
                    }
            } header: {
                Text("Уведомления")
            }
        }
        .settingsPage("Оповещения и звук")
    }
}

// MARK: - Скорость

struct SpeedSettingsPage: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Form {
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
            } footer: {
                Text("Знак лимита дороги на панели и голос при превышении. Допуск — на сколько можно превысить, прежде чем приложение сочтёт это превышением.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPage("Скорость")
    }
}

// MARK: - Поездка

struct TripSettingsPage: View {
    @Environment(AppEnvironment.self) private var env
    @State private var allTracks: ShareFilePayload?

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section {
                Picker("Старт поездки", selection: $settings.tripStartMode) {
                    ForEach(TripStartMode.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: settings.tripStartMode) { _, _ in env.motion.syncEnabled() }
            } footer: {
                SettingsFootnote([
                    "«Умный» — поездка включается сама только в вашей машине (CarPlay или знакомая магнитола); в чужой сначала спросит «вы за рулём?».",
                    "«Авто» — всегда сама. «Ручной» — только кнопкой, слежение за движением выключено совсем.",
                    "Заезд по пути — магазин, заправка — новой поездкой не становится: это остановка внутри той же.",
                ])
            }

            Section {
                Toggle("Подробный трек для регистратора", isOn: $settings.recordTimedTrack)
                    .onChange(of: settings.recordTimedTrack) { _, on in
                        env.trip.recordsTimedTrack = on
                    }
                Button("Выгрузить все поездки (GPX)") {
                    if let url = TimedTrackStore.gpxFile(forAll: env.trip.history) {
                        allTracks = ShareFilePayload(url: url)
                    }
                }
                .disabled(env.trip.history.isEmpty)
            } footer: {
                Text("Точка каждую секунду со временем — чтобы видео с регистратора можно было поставить на карту. Хранится только на телефоне 30 дней. «Выгрузить все поездки» отдаёт один файл GPX: линии поездок последней недели и проезды камер за месяц.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Не гасить экран в поездке", isOn: $settings.keepScreenOn)
                    .onChange(of: settings.keepScreenOn) { _, keepOn in
                        if env.location.isTripActive {
                            UIApplication.shared.isIdleTimerDisabled = keepOn
                        }
                    }
            } header: {
                Text("Экран")
            } footer: {
                Text("Экран в поездке не засыпает, как у навигаторов. Выключите — и он погаснет по таймеру iOS; о камерах приложение предупредит голосом и с погашенным экраном, при доступе «Всегда».")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPage("Поездка")
        .sheet(item: $allTracks) { payload in
            ActivityFileSheet(url: payload.url)
                .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Маршрут

struct RouteSettingsPage: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section {
                Toggle("Голосовая навигация", isOn: $settings.turnByTurnVoice)
                Toggle("Варианты маршрута", isOn: $settings.routeAlternatives)
                Toggle("Следующая камера в панели", isOn: $settings.showNextCamera)
            } footer: {
                Text("Подсказки манёвров «через 300 м направо» и выбор из нескольких вариантов при построении. Панель маршрута может показывать ближайшую камеру по курсу.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Учитывать мои поездки", isOn: $settings.personalRoutes)
                    .disabled(!settings.routeAlternatives)
            } footer: {
                SettingsFootnote([
                    "Варианты сравниваются с вашими поездками: «Знакомый» — путь, которым вы уже ездили, «Спокойнее» — без камер, где вы раньше превышали.",
                    "Знакомый предлагается первым, если он ненамного дольше быстрого.",
                    "Всё считается на телефоне и никуда не отправляется.",
                ])
            }
        }
        .settingsPage("Маршрут")
    }
}

// MARK: - Карта

struct MapSettingsPage: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section {
                Picker("Тема", selection: $settings.mapAppearance) {
                    ForEach(MapAppearance.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("«Авто» — днём светлые панели и карта (тёмное на солнце бликует), ночью графитовые. Экран тревоги тёмный всегда.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                CursorStylePicker(selection: $settings.cursorStyle)
            } header: {
                Text("Значок на карте")
            } footer: {
                Text("Так вы выглядите на карте — на телефоне и в CarPlay. Значок поворачивается по ходу движения.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Тип камер", selection: $settings.filter) {
                    ForEach(CameraFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Камеры на карте")
            }

            Section {
                Toggle("Кнопки масштаба", isOn: $settings.mapZoomButtons)
                NavigationLink {
                    OfflineMapsView().settingsPage()
                } label: {
                    Text("Офлайн-карты")
                }
            } footer: {
                Text("Чем рисовать карту — Apple, своя схема или движок — выбирается кнопкой слоёв на самой карте: там виден результат, и переключение действует сразу.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPage("Карта")
    }
}

// MARK: - Мои места

struct PlacesSettingsPage: View {
    @Environment(AppEnvironment.self) private var env
    @State private var assignSlot: PlaceSlot?
    /// «Выбрать на карте» — тот же экран, что у «Моих мест» в баре.
    @State private var pickSlot: PlaceSlot?

    var body: some View {
        Form {
            Section {
                ForEach(PlaceSlot.allCases) { slot in
                    placeRow(slot)
                }
            } footer: {
                Text("Маршрут в один тап — кнопкой «Мои места» на карте или из «Поиска». Адрес можно найти словами или показать на карте.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPage("Мои места")
        .sheet(item: $assignSlot) { slot in
            SearchView(initialAssign: slot)
        }
        .fullScreenCover(item: $pickSlot) { slot in
            PlacePickerMap(slot: slot, start: .init(for: slot, env: env))
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
            // Два пути вместо одного: раньше «Задать» вело только в поиск, а
            // дом без номера в OSM словами не находится («там выбор по карте
            // нет»).
            PlaceAssignMenu(onSearch: { assignSlot = slot }, onMap: { pickSlot = slot }) {
                PlaceAssignLabel(isSet: place != nil)
            }
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
}

// MARK: - Приложение учится

/// Что приложение выучивает само. Эти вещи меняют поведение молча (камера
/// перестала называться вслух, на экране появилась подсказка «Домой»),
/// поэтому им нужен и тумблер, и объяснение: необъяснённая догадка
/// читается как сбой.
struct LearningSettingsPage: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Form {
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
            } footer: {
                SettingsFootnote([
                    "Камеру, которую вы проезжаете шесть и больше раз за месяц и ни разу с превышением, приложение перестаёт называть вслух. На карте у неё галочка, предупреждение остаётся.",
                    "Одно превышение — и она снова говорит. О передвижных радарах, треногах и ДТП голос звучит всегда.",
                    "Дом и работа определяются по распорядку: куда вы приезжаете вечером и куда утром буднего дня.",
                    "Всё считается на телефоне и никуда не отправляется.",
                ])
            }
        }
        .settingsPage("Приложение учится")
    }
}

// MARK: - Батарея

struct BatterySettingsPage: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section {
                Toggle("Адаптивный GPS", isOn: $settings.adaptiveGPS)
                    .onChange(of: settings.adaptiveGPS) { _, _ in
                        // Иначе выключение в поездке залипало бы на последнем тире.
                        env.location.refreshLocationMode()
                    }
            } footer: {
                Text("Вдали от камер и манёвров точность GPS снижается, у самой камеры возвращается к максимальной. Выключать стоит, только если кажется, что оповещения запаздывают.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPage("Батарея")
    }
}

// MARK: - Конфиденциальность

struct PrivacySettingsPage: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section {
                Toggle("Помогать улучшать приложение", isOn: $settings.usageStatsEnabled)
            } footer: {
                Text("Раз в сутки отправляем обезличенные счётчики: сколько поездок, километров и оповещений было. Ни маршрутов, ни координат, ни времени — только числа. Идентификатор меняется каждые 30 дней.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Link(destination: AppConfig.privacyPolicyURL) {
                    HStack {
                        Text("Политика конфиденциальности")
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            } footer: {
                Text("Что уходит на сервер и что остаётся только на телефоне.")
            }
        }
        .settingsPage("Конфиденциальность")
    }
}

// MARK: - Помощь

/// Ответы на вопросы, которые чаще всего приходят в «Написать разработчику».
/// Каждый ответ ведёт к месту в приложении, где это решается, — а не
/// объясняет устройство: за рулём нужен путь, а не теория.
struct HelpSettingsPage: View {
    private struct Item {
        let question: LocalizedStringKey
        let answer: LocalizedStringKey
    }

    private let items: [Item] = [
        Item(question: "Почему приложение не сказало о камере?",
             answer: "Проверьте звук — кнопка с динамиком на карте. О камерах, которые вы часто проезжаете без превышения, приложение молчит намеренно: на карте у них зелёная галочка (Настройки → Приложение учится). Скрытую камеру можно вернуть в Настройках → База камер → Скрытые камеры. Если ничего не подошло — нажмите «Не предупредила о камере» у этого проезда в Итогах, мы разберём случай."),
        Item(question: "Зачем доступ к геопозиции «Всегда»?",
             answer: "Без него iOS не даёт предупреждать о камерах, когда приложение свёрнуто или экран погашен, и поездка не начинается сама. Фоновая геопозиция обрабатывается только на телефоне."),
        Item(question: "Сколько тратится батареи?",
             answer: "Вне поездки — почти ничего: приложение просыпается только у камер. В поездке GPS работает постоянно, но вдали от камер точность снижается сама (Настройки → Батарея). Больше всего тратит экран: если смотреть на карту не нужно, погасите его — при доступе «Всегда» о камерах приложение предупредит голосом и с погашенным экраном."),
        Item(question: "Что значат полупрозрачные отметки с «?»",
             answer: "Это отметки водителей, которые ещё никто не подтвердил. Приложение предупреждает и о них, но говорит, что это отметка водителей. Подтвердить или опровергнуть можно в карточке отметки или ответом на вопрос «радар ещё стоял?» после проезда."),
        Item(question: "Камеры уже нет или она стоит не там",
             answer: "Откройте карточку камеры и нажмите «Камеры больше нет» или «Неверное место». Модератор проверит и поправит базу для всех. До проверки камера продолжает предупреждать — так безопаснее."),
        Item(question: "Как перенести поездки на новый телефон?",
             answer: "Настройки → Мои данные → «Сохранить копию», затем на новом телефоне — «Восстановить из файла». История хранится только на телефоне, на сервер мы её не отправляем."),
        Item(question: "Почему маршрут не строится без интернета?",
             answer: "Маршрут считает наш сервер. Без связи карта скачанной области и предупреждения о камерах работают, а новый маршрут — нет."),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    DisclosureGroup {
                        Text(item.answer)
                            .font(.rounded(15))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                    } label: {
                        Text(item.question)
                            .font(.rounded(15, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
            } footer: {
                Text("Не нашли ответа — напишите нам: Настройки → Написать разработчику.")
            }
        }
        .settingsPage("Помощь")
    }
}

// MARK: - Мои данные

/// Резервная копия поездок и своих камер: сохранить файл и восстановить из
/// него (BackupSection — сама логика и тексты).
struct BackupSettingsPage: View {
    var body: some View {
        Form {
            BackupSection()
        }
        .settingsPage("Мои данные")
    }
}

// MARK: - Скрытые камеры

/// Камеры, которые человек скрыл у себя. Скрытая камера не только пропадает с
/// карты, но и МОЛЧИТ — поэтому список говорит об этом прямо и возвращает
/// камеру одним касанием. До него скрытие было необратимым.
struct HiddenCamerasPage: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let cameras = env.cameras.hiddenCameras
        Form {
            Section {
                ForEach(cameras) { camera in
                    HStack(spacing: 12) {
                        Image(systemName: camera.kind.symbolName)
                            .font(.rounded(13, .bold))
                            .foregroundStyle(camera.kind.glyphTint)
                            .frame(width: 30, height: 30)
                            .background(camera.kind.tint, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(camera.displayTitle)
                                .font(.rounded(15, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(2)
                            Text(camera.kind.displayName)
                                .font(.rounded(12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Button("Вернуть") { env.cameras.unhide(id: camera.id) }
                            .font(.rounded(15, .semibold))
                            .buttonStyle(.borderless)
                            .tapTarget()
                    }
                }
            } footer: {
                Text("Скрытая камера не показывается на карте и не предупреждает.")
            }
            if env.cameras.hiddenIDs.count > cameras.count || cameras.count > 1 {
                Section {
                    Button("Вернуть все") { env.cameras.unhideAll() }
                }
            }
        }
        .settingsPage("Скрытые камеры")
    }
}

// MARK: - База камер

struct DatabaseSettingsPage: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Section {
                LabeledContent("Версия базы", value: "v\(env.cameras.dbVersion)")
                LabeledContent("Своих камер", value: "\(env.cameras.custom.count)")
                if !env.cameras.hiddenIDs.isEmpty {
                    NavigationLink {
                        HiddenCamerasPage()
                    } label: {
                        LabeledContent("Скрытые камеры", value: "\(env.cameras.hiddenIDs.count)")
                    }
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
            } footer: {
                if let date = env.sync.lastCheckDate {
                    Text("Последняя проверка: \(date.formatted(date: .abbreviated, time: .shortened))")
                }
            }
        }
        .settingsPage("База камер")
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

// MARK: - Язык

struct LanguageSettingsPage: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showRestart = false

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section {
                Picker("Язык приложения", selection: $settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: settings.appLanguage) { _, _ in
                    showRestart = true
                }
            } footer: {
                Text("Язык применяется полностью после перезапуска приложения.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsPage("Язык")
        .alert("Язык изменён", isPresented: $showRestart) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Перезапустите приложение, чтобы язык применился полностью.")
        }
    }
}
