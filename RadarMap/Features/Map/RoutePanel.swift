//
//  RoutePanel.swift
//  RadarMap
//
//  Панель активного маршрута: варианты, цель, время/расстояние, камеры по пути,
//  «Поехали». Плюс баннер манёвра (turn-by-turn). Панель поездки — TripLiveBar.swift.
//

import SwiftUI
import CoreLocation

struct RoutePanel: View {
    @Environment(AppEnvironment.self) private var env
    let onShowCameras: () -> Void
    let onTripToggle: () -> Void
    /// Убрать заезд, оставив цель.
    var onRemoveStop: () -> Void = {}
    /// «Поделиться прибытием» до старта — пока человек ещё стоит и может
    /// выбрать, кому написать (5.13).
    var onShareArrival: (() -> Void)?
    /// «По пути» (19.3): заправки, гостиницы, кафе впереди — лист со списком.
    var onShowAlongRoute: (() -> Void)?
    /// «Перед дальней дорогой» (12.4): маршрут длиннее 100 км — карта по
    /// пути, камеры и посты по порядку, где заправиться.
    var onShowLongTrip: (() -> Void)?
    /// Выбран вариант карточкой: хозяин экрана выбирает его и возвращает кадр
    /// «весь маршрут» (27.D) — карточка говорит «покажи этот», и карту, которую
    /// человек перед этим отодвинул, надо вернуть.
    var onSelectVariant: ((Int) -> Void)?

    var body: some View {
        let route = env.route
        VStack(spacing: 10) {
            // Выбор варианта — только пока стоим и есть из чего выбирать.
            if route.variants.count > 1, !env.location.isTripActive {
                variantChips
                if let selected = route.selected, let why = Self.reason(selected, among: route.variants) {
                    Text(why)
                        .font(.rounded(12, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        // Сплошная, как карточки: стекло над картой пропускало
                        // подписи улиц сквозь строку (27.D).
                        .liftedBackground(Theme.surface, in: Capsule())
                        .contentTransition(.opacity)
                }
            }

            // Маршрут по своему графу трасс (12б.10): без запретов поворотов и
            // без подсказок манёвров — так и сказать. Связь вернётся — его
            // молча заменит серверный.
            if route.selected?.isOffline == true {
                Label("Маршрут без сети, приблизительно", systemImage: "wifi.slash")
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .liftedBackground(Theme.surface, in: Capsule())
            }

            summaryCard
        }
        .motionAnimation(Motion.standard, value: route.selectedID)
        .motionAnimation(Motion.standard, value: env.location.isTripActive)
    }

    // MARK: - Сводка и «Поехали»

    /// Время — герой (этап 31, выбор владельца 26.10; как у Яндекса): первое,
    /// что ищут глазами, — «сколько ехать». Ниже путь, флаг и время прибытия,
    /// пробки словами; «Поехали», камеры числом и «…» — одной строкой.
    /// Сплошная панель, а не стекло: днём стекло было белёсым, а бледные
    /// круги «поделиться» и «по пути» читались выключенными. Док главного
    /// экрана на это время уходит (MapScreen.bottomPanels).
    private var summaryCard: some View {
        let route = env.route
        let shape = RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(route.destinationName)
                        .font(.rounded(12, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Text(verbatim: route.etaText)
                        .font(.numeral(30, .heavy))
                        .foregroundStyle(route.trafficNote == nil ? Theme.textPrimary
                                         : Self.trafficTint(route.trafficDelay ?? 0))
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    // Подпись пробок не влезла в строку (SE, «обычно +12 мин в
                    // это время») — своей строкой ниже, а не многоточием.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            pathAndArrival
                            if let note = route.trafficNote {
                                Text(verbatim: "·").foregroundStyle(Theme.textTertiary)
                                trafficNoteText(note)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) { pathAndArrival }
                            if let note = route.trafficNote { trafficNoteText(note) }
                        }
                    }
                    .font(.rounded(12, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    // Заезд по пути — видно, что цель та же, а линия идёт
                    // через остановку.
                    if let stop = route.stop {
                        stopRow(stop.name)
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
                Button { route.clear() } label: {
                    Image(systemName: "xmark")
                        .font(.rounded(12, .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Theme.background, in: Circle())
                        .tapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Сбросить маршрут"))
            }
            if let onShowLongTrip, let selected = route.selected, RouteCorridor.isLong(selected.distance) {
                longTripRow(onShowLongTrip)
            }
            // В поездке панель заменяется компактной TripLiveBar — здесь всегда «до старта».
            HStack(spacing: 8) {
                PrimaryButton(title: "Поехали", systemImage: "play.fill", action: onTripToggle)
                camerasPlate
                moreMenu
            }
        }
        .padding(14)
        .liftedBackground(Theme.surface, in: shape)
        .overlay(shape.strokeBorder(Theme.edgePanel, lineWidth: 1))
    }

    /// «8,2 км · 🏁 15:56» — путь и прибытие (тем же временем, что крупная цифра).
    @ViewBuilder private var pathAndArrival: some View {
        Text(verbatim: env.route.distanceText)
        Text(verbatim: "·").foregroundStyle(Theme.textTertiary)
        Image(systemName: "flag.checkered").font(.rounded(12, .semibold))
            .accessibilityHidden(true)
        Text(env.route.arrivalDate, style: .time)
    }

    private func trafficNoteText(_ note: String) -> some View {
        Text(verbatim: note).foregroundStyle(Self.trafficTint(env.route.trafficDelay ?? 0))
    }

    /// Строка «Перед дальней дорогой» — видна сразу, а не в «…»: на трассе без
    /// связи её содержимое уже не узнать, и спрашивать надо до «Поехали».
    private func longTripRow(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "road.lanes")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("Перед дальней дорогой")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.rounded(13, .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: Theme.controlSize)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint(Text("Карта по пути, камеры и посты, где заправиться"))
    }

    private func stopRow(_ name: String) -> some View {
        HStack(spacing: 6) {
            Label(String(format: String(localized: "через %@"), name),
                  systemImage: "mappin.circle.fill")
                .font(.rounded(12, .semibold))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
            Button(action: onRemoveStop) {
                Image(systemName: "xmark")
                    .font(.rounded(10, .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Theme.background, in: Circle())
                    .tapTarget()
            }
            .buttonStyle(.plain)
            .disabled(env.route.isBuilding)
            .accessibilityLabel(Text("Убрать заезд"))
        }
    }

    /// Камеры на маршруте — числом под значком, высотой с «Поехали». Нет
    /// камер — зелёный значок и 0, как раньше.
    private var camerasPlate: some View {
        let route = env.route
        return Button(action: onShowCameras) {
            VStack(spacing: 0) {
                SymbolIcon(Icon.cameras, size: 13, weight: .bold)
                    .foregroundStyle(route.ourCameraCount == 0 ? Theme.success : Theme.Types.camera)
                Text(verbatim: "\(route.ourCameraCount)")
                    .font(.rounded(15, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(width: 56, height: 54)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(route.camerasOnRoute.isEmpty)
        .accessibilityLabel(Text("Камеры на маршруте"))
        .accessibilityValue(Text("\(route.ourCameraCount) камер"))
    }

    /// «По пути» и «Поделиться прибытием» — пунктами: значками в ряд они
    /// выглядели выключенными и сжимали камеры в две строки.
    @ViewBuilder private var moreMenu: some View {
        let canShare = onShareArrival != nil && env.etaShare.isAvailable && !env.etaShare.isSharing
        if onShowAlongRoute != nil || canShare {
            Menu {
                if let onShowAlongRoute {
                    Button(action: onShowAlongRoute) {
                        Label("По пути", systemImage: AlongRouteText.symbol(env.settings.vehicleEnergy))
                    }
                }
                if canShare, let onShareArrival {
                    Button(action: onShareArrival) {
                        Label("Поделиться прибытием", systemImage: "square.and.arrow.up")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.rounded(17, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 48, height: 54)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            }
            .accessibilityLabel(Text("Ещё"))
        }
    }

    // MARK: - Варианты маршрута

    private var variantChips: some View {
        // Строка ярлыка и строка пробок есть у всех карточек, если они есть
        // хоть у одной, — иначе карточки разной высоты прыгают.
        let variants = env.route.variants
        let labeled = variants.contains { !$0.assessment.labels.isEmpty }
        let traffic = variants.contains { Self.trafficLine($0) != nil }
        return HStack(spacing: 8) {
            ForEach(variants) { variant in
                variantChip(variant, labeled: labeled, traffic: traffic)
            }
        }
        // Любое касание карточек (и жест мимо кнопки) — выбор начался: ярлыки
        // по поздним пробкам больше не двигаются (ChoiceRelabelGate, 28.10).
        // Одновременный жест кнопкам не мешает; повтор — без записи.
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in env.route.noteChoiceTouched() })
    }

    /// Карточка варианта (27.D — крупнее и яснее): ярлык, время с пробками
    /// крупно, путь и камеры, задержка пробками; снизу полоска цвета его линии
    /// на карте — по ней карточку и линию связывает глаз.
    private func variantChip(_ variant: RouteService.Variant, labeled: Bool, traffic: Bool) -> some View {
        let isSelected = variant.id == env.route.selectedID
        let delay = variant.shownTrafficDelay ?? 0
        let line = Self.trafficLine(variant)
        return Button {
            if let onSelectVariant {
                onSelectVariant(variant.id)
            } else {
                env.route.selectVariant(variant.id)
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if labeled {
                    Text(variant.assessment.labels.first.map { Self.title($0, variant) } ?? " ")
                        .font(.rounded(12, .bold))
                        // «Перекрытие» — предупреждение, а не достоинство: янтарём.
                        .foregroundStyle(isSelected ? Theme.onAccentFill
                                         : variant.assessment.closures > 0 ? Theme.warning : Theme.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Text(variant.etaText)
                    .font(.numeral(21, .heavy))
                    .foregroundStyle(isSelected ? Theme.onAccentFill
                                     : delay >= AppConfig.routeTrafficNoticeSeconds
                                        ? Self.trafficTint(delay) : Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 4) {
                    Text(variant.distanceText)
                    SymbolIcon(Icon.cameras, size: 10)
                    Text("\(variant.ourCameraCount)")
                }
                .font(.rounded(12, .semibold))
                .foregroundStyle(isSelected ? Theme.onAccentFillSecondary : Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                if traffic {
                    Label(line ?? " ", systemImage: "car.2.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.rounded(11, .bold))
                        .foregroundStyle(isSelected ? Theme.onAccentFillSecondary : Self.trafficTint(delay))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .opacity(line == nil ? 0 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.top, 10)
            .padding(.bottom, 13)
            .background(isSelected ? Theme.accentFill : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .overlay(alignment: .bottom) {
                // Цвет линии этого варианта на карте. У выбранного линия того
                // же синего, что заливка карточки, — полоска не нужна.
                if !isSelected {
                    Capsule()
                        .fill(Theme.routeAlternative)
                        .frame(height: 4)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 5)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                .stroke(isSelected ? .clear : Theme.stroke, lineWidth: 1))
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: Theme.panelShadow, radius: 8, y: 2)
            }
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
        // Выбор закодирован только цветом — VoiceOver должен его слышать (4.6).
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Строка пробок на карточке: «+7 мин», «без пробок»; данных нет — nil.
    /// Короче строки карточки маршрута: на SE три карточки по 110 pt.
    static func trafficLine(_ variant: RouteService.Variant) -> String? {
        guard let delay = variant.shownTrafficDelay else { return nil }
        if delay < 60 { return variant.trafficNote }
        // Знак и число одинаковы в обоих языках; единица — из Formatting.
        return "+" + Formatting.unbreakable(Formatting.duration(delay))
    }

    /// Цвет пробки на маршруте: заметная задержка — янтарь, большая — красный,
    /// без пробок — зелёный. Пороги — общие с машиной (RoutePreview.trafficTone).
    static func trafficTint(_ delay: TimeInterval) -> Color {
        switch RoutePreview.trafficTone(delay: delay) {
        case .heavy:           return Theme.danger
        case .slow:            return Theme.warning
        case .free, .unknown:  return Theme.success
        }
    }

    // MARK: - Ярлыки вариантов (RouteChoice)

    static func title(_ label: RouteChoice.Label, _ variant: RouteService.Variant) -> String {
        switch label {
        case .blocked:         return String(localized: "Перекрытие")
        case .myRoad:          return String(localized: "Моя дорога")
        case .familiar:        return String(localized: "Знакомый")
        case .fastest:         return String(localized: "Быстрый")
        case .fewerCameras:    return variant.ourCameraCount == 0
                                   ? String(localized: "Без камер") : String(localized: "Меньше камер")
        case .avoidsOverspeed: return String(localized: "Спокойнее")
        case .simpler:         return String(localized: "Проще")
        case .shortest:        return String(localized: "Короткий")
        }
    }

    /// Почему вариант такой — одной строкой под плашками. Числа рядом с
    /// ярлыком: «Знакомый» без «поездок этим путём: 12» — просто слово.
    static func reason(_ variant: RouteService.Variant, among all: [RouteService.Variant]) -> String? {
        // Быстрый — тот, кого так назвал выбор (по времени с пробками); его
        // нет — меньшее время с пробками.
        guard let fastest = all.first(where: { $0.assessment.labels.contains(.fastest) })
                ?? all.min(by: { $0.expectedTime < $1.expectedTime }) else { return nil }
        let a = variant.assessment
        var parts: [String] = []
        for label in a.labels {
            switch label {
            case .myRoad:
                if let mine = a.myRoad { parts.append(myRoadReason(mine)) }
            case .familiar where a.myRoad != nil:
                break   // своя дорога и так знакома — второе слово лишнее
            case .blocked:
                parts.append(a.closures == 1
                             ? String(localized: "на пути перекрытие — отметка водителей")
                             : String(format: String(localized: "на пути перекрытий: %lld — отметки водителей"),
                                      a.closures))
            case .familiar:
                parts.append(String(format: String(localized: "поездок этим путём: %lld"), a.familiarTrips))
            case .fewerCameras:
                parts.append(String(format: String(localized: "камер: %1$lld вместо %2$lld"),
                                    variant.ourCameraCount, fastest.ourCameraCount))
            case .avoidsOverspeed:
                parts.append(String(format: String(localized: "без камер, где вы превышали (на быстром: %lld)"),
                                    fastest.assessment.overspeedCameras))
            case .simpler:
                if let mine = a.hardManeuvers, let base = fastest.assessment.hardManeuvers {
                    parts.append(String(format: String(localized: "сложных манёвров: %1$lld вместо %2$lld"),
                                        mine, base))
                }
            case .shortest:
                parts.append(String(format: String(localized: "на %@ короче"),
                                    Formatting.distance(fastest.distance - variant.distance)))
            case .fastest:
                break
            }
        }
        // Разница тех чисел, что на карточках (с личным темпом).
        let extra = variant.shownTime - fastest.shownTime
        if variant.id != fastest.id, extra >= 60 {
            parts.append(String(format: String(localized: "+%@ к быстрому"), Formatting.duration(extra)))
        }
        guard !parts.isEmpty else { return nil }
        let head = a.labels.first.map { title($0, variant) }
        return ([head].compactMap { $0 } + parts).joined(separator: " · ")
    }

    /// «Так вы ездите домой — обычно 39 мин»: время по своим поездкам этого
    /// часа без сегодняшних пробок (они — отдельной строкой в карточке).
    /// Своих поездок в этот час мало — без минут, только откуда ярлык.
    static func myRoadReason(_ mine: RouteChoice.Personal) -> String {
        guard let seconds = mine.seconds else {
            return mine.direction == .toHome ? String(localized: "так вы ездите домой")
                                             : String(localized: "так вы ездите на работу")
        }
        let usual = Formatting.unbreakable(Formatting.duration(max(0, seconds - mine.jamSeconds)))
        return mine.direction == .toHome
            ? String(format: String(localized: "так вы ездите домой — обычно %@"), usual)
            : String(format: String(localized: "так вы ездите на работу — обычно %@"), usual)
    }

}

/// Баннер ближайшего манёвра (turn-by-turn) — крупно, читается боковым зрением.
struct ManeuverBanner: View {
    let step: RouteStep
    let distance: CLLocationDistance
    /// Скорость — только для того, когда показать ряд полос (на трассе раньше).
    var speedKmh: Double = 0
    /// Второй манёвр сразу за этим (ManeuverThen, 29.G); nil — далеко или нет.
    var then: RouteStep? = nil
    /// Манёвр, для которого ряд полос уже показан: дальше он не прячется.
    /// Порог зависит от скорости, и на 68–72 км/ч между 600 и 1000 м ряд
    /// мигал бы — появился, исчез, появился.
    @State private var lanesShownFor: CLLocationDistance?
    /// Карточка манёвра — синяя заливка с белым текстом (вариант А, 10.10):
    /// главный предмет экрана в поездке, и он должен отделяться от белых
    /// панелей и от карты одним взглядом, как у Amap. Раньше это была ещё
    /// одна белая карточка среди белых карточек.
    private let fill = Theme.accentFill
    private let ink = Theme.onAccentFill

    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 12) {
            Image(systemName: step.icon)
                .font(.rounded(24, .bold))
                .foregroundStyle(ink)
                .frame(width: 52, height: 52)
                .background(ink.opacity(0.18), in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                // Моноширинные цифры — как у приборки и CarPlay: дистанция
                // тает каждый тик, и без них баннер дрожал шириной.
                Text(Formatting.distance(distance))
                    .font(.numeral(30, .bold).monospacedDigit())
                    .foregroundStyle(ink)
                    .liveNumber()
                Text(step.text)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.onAccentFillSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        if let edge = step.laneEdge, showsLaneRow {
            Rectangle().fill(ink.opacity(0.22)).frame(height: 1)
            // Полос от OSRM нет — край словами и значком «к кромке»: ряд
            // стрелок по догадке рисовать нельзя, а «перестройтесь в левый
            // ряд» — правило ПДД для многополосного подъезда (20.3).
            HStack(spacing: 10) {
                Image(systemName: LaneAdvice.symbol(edge))
                    .font(.rounded(20, .heavy))
                    .foregroundStyle(fill)
                    .frame(width: 44, height: 34)
                    .background(ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(LaneAdvice.spoken(edge))
                    .font(.rounded(16, .bold))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
        }
        if !step.lanes.isEmpty, step.lanes.count <= 8,
           step.lanes.contains(where: \.isValid), showsLaneRow {
            Rectangle().fill(ink.opacity(0.22)).frame(height: 1)
            // Как у Amap: ряд полос — сама дорога, полосы разделены
            // разметкой, нужные — залиты белым, и над рядом словами,
            // в какой ряд встать: считать стрелки на ходу — лишний взгляд.
            VStack(spacing: 6) {
                if let advice = LaneAdvice.phrase(step.lanes) {
                    Text(advice)
                        .font(.rounded(15, .bold))
                        .foregroundStyle(ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 0) {
                    ForEach(Array(step.lanes.enumerated()), id: \.offset) { index, lane in
                        if index > 0 {
                            // Высота разделителя — своя, а не «сколько дадут»:
                            // прямоугольник без высоты растягивал весь ряд на
                            // высоту экрана (снимок 21.10 — пол-экрана синей
                            // панели под карточкой манёвра).
                            Rectangle()
                                .fill(ink.opacity(0.3))
                                .frame(width: 1.5, height: 28)
                        }
                        Image(systemName: lane.primaryArrow(for: step.kind).symbolName)
                            .font(.rounded(24, lane.isValid ? .heavy : .regular))
                            .foregroundStyle(lane.isValid ? fill : ink.opacity(0.45))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(lane.isValid ? ink : .clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(.horizontal, 3)
                            .accessibilityLabel(Text("Полоса \(index + 1)"))
                            .accessibilityValue(lane.isValid ? Text("Подходит для манёвра") : Text("Не подходит для манёвра"))
                    }
                }
                .padding(4)
                .background(ink.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
        }
        if let then, distance <= AppConfig.maneuverThenShowMeters {
            Rectangle().fill(ink.opacity(0.22)).frame(height: 1)
            // «Затем ↰» — как у Яндекса: второй поворот близко, и ряд под
            // него выбирают ещё до первого.
            HStack(spacing: 8) {
                Text("Затем")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.onAccentFillSecondary)
                Image(systemName: then.icon)
                    .font(.rounded(18, .heavy))
                    .foregroundStyle(ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(String(format: String(localized: "Затем: %@"), then.text)))
        }
        }
        .liftedBackground(fill, in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous).stroke(ink.opacity(0.12), lineWidth: 1))
        .transition(.move(edge: .top).combined(with: .opacity))
        .onChange(of: distance <= LaneAdvice.showDistance(speedKmh: speedKmh), initial: true) { _, near in
            if near { lanesShownFor = step.distanceAlong }
        }
    }

    /// Ряд (стрелки или край) — на подходе, и раз показанный уже не прячется.
    private var showsLaneRow: Bool {
        lanesShownFor == step.distanceAlong || distance <= LaneAdvice.showDistance(speedKmh: speedKmh)
    }
}

/// Ограничение полос на перекрёстке, который проезжаем прямо: «через 200 м —
/// из левых рядов» и короткий ряд стрелок. Меньше баннера манёвра: это не
/// команда, а предупреждение не оказаться в ряду «только направо».
struct LaneNoticeBanner: View {
    let lanes: [LaneHint]
    let distance: CLLocationDistance

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Formatting.distance(distance))
                    .font(.rounded(15, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .liveNumber()
                Text(LaneAdvice.phrase(lanes) ?? String(localized: "Ряд для проезда прямо"))
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ForEach(Array(lanes.enumerated()), id: \.offset) { index, lane in
                    Image(systemName: lane.primaryArrow(for: .straight).symbolName)
                        .font(.rounded(16, lane.isValid ? .heavy : .regular))
                        .foregroundStyle(lane.isValid ? Theme.onAccentFill : Theme.textTertiary)
                        .frame(width: 26, height: 28)
                        .background(lane.isValid ? Theme.accentFill : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityLabel(Text("Полоса \(index + 1)"))
                        .accessibilityValue(lane.isValid ? Text("Подходит для манёвра") : Text("Не подходит для манёвра"))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .liftedBackground(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerPanel, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Список камер вдоль маршрута — по порядку следования.
struct RouteCamerasSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onSelect: (Camera) -> Void

    var body: some View {
        NavigationStack {
            List(Array(env.route.camerasOnRoute.enumerated()), id: \.element.id) { index, item in
                Button {
                    onSelect(item.camera)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.rounded(13, .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 24)
                        CameraIcon(kind: item.camera.kind, side: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.camera.displayTitle)
                                .font(.rounded(14, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text("\(Formatting.distance(item.distanceAlong)) от старта")
                                .font(.rounded(12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .listRowBackground(Theme.surface)
                .listRowSeparatorTint(Theme.stroke)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Камеры на маршруте")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
