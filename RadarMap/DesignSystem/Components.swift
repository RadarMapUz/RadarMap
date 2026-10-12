//
//  Components.swift
//  RadarMap
//
//  Переиспользуемые элементы тёмного интерфейса.
//

import SwiftUI
import UIKit

/// Панель стоит над светлой подложкой карты (дневная тема): фон карточек
/// уплотняется, иначе белые цифры на солнце теряются в полупрозрачном стекле.
/// Флаг, а не смена colorScheme: интерфейс обязан остаться тёмным, иначе
/// системные материалы посветлеют вместе с белым текстом на них.
private struct OnLightMapKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var onLightMap: Bool {
        get { self[OnLightMapKey.self] }
        set { self[OnLightMapKey.self] = newValue }
    }
}

/// «Стеклянная» карточка — базовый контейнер интерфейса (нативный Liquid Glass).
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.cornerLarge
    @ViewBuilder var content: Content
    @Environment(\.onLightMap) private var onLightMap

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let veil = onLightMap ? 0.62 : 0.32
        content
            // Тёмная подложка под стеклом: на светлой карте чистое стекло
            // белеет, и белый текст по нему исчезает.
            //
            // Тень — у ПОДЛОЖКИ, а не у всей панели. `.shadow` на составной
            // вью SwiftUI накладывает на каждый вложенный элемент: каждая
            // цифра скорости получала своё размытие, и оно пересчитывалось
            // на каждом тике GPS. Сила тени умножается на прозрачность
            // заливки, поэтому цвет тени поделён на неё — на глаз как было.
            .background {
                shape.fill(Theme.background.opacity(veil))
                    .shadow(color: .black.opacity(min(0.25 / veil, 0.8)), radius: 14, y: 6)
            }
            .backport.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            // Световая кромка сверху — единый премиальный язык стекла в приложении.
            .overlay(shape.strokeBorder(Theme.edgePanel, lineWidth: 1))
    }
}

/// Знак-иконка: SF Symbol в цветном круге. Один язык иконок во всём
/// приложении: глаз находит строку по цвету и форме раньше, чем прочтёт
/// подпись. Круг — потому что так Итоги, подсказки и разделы и были
/// нарисованы, только каждый раз руками и с разной заливкой. Цвет — по
/// СМЫСЛУ (`Theme.Icon`), а не по вкусу экрана: время всегда одного цвета,
/// деньги — другого.
struct IconBadge: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Панель поверх ЖИВОЙ карты — сплошная заливка вместо стекла.
///
/// Стекло (`glassEffect`, материалы) размывает то, что под ним, и пока карта
/// под панелью едет, система заново считает размытие на каждом её кадре —
/// всю поездку, на сервере рендеринга (backboardd +32 % на ходу в профиле
/// 11.10). Над картой, которая стоит (маршрут до старта, постановка камеры),
/// стекло остаётся: там оно бесплатно.
struct SolidPanel<Content: View>: View {
    var cornerRadius: CGFloat = Theme.cornerLarge
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .liftedBackground(Theme.surface, in: shape)
            .overlay(shape.strokeBorder(Theme.edgePanel, lineWidth: 1))
    }
}

/// Единый контейнер карточки статистики: одинаковые отступы, радиус и фон.
/// Раньше каждый блок Итогов задавал их сам и они расходились на пару пунктов.
extension View {
    func statCard(padding: CGFloat = 16, radius: CGFloat = Theme.cornerLarge) -> some View {
        self.padding(padding)
            .background {
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                // Заливка градиентом, а не краской: на почти чёрном фоне объём
                // даёт перепад светлоты, а не тень — тени там попросту не видно.
                shape.fill(Theme.surfaceRaised)
                    // Тень — только у ФОРМЫ карточки. До 11.10 `.shadow` висел
                    // на всей карточке, и SwiftUI размывал каждый вложенный
                    // элемент отдельно: под каждой цифрой и строкой лежал серый
                    // ореол (видно на скриншотах Итогов), а прокрутка считала
                    // сотни размытий на кадр — отсюда «лагает жёстко». Тень
                    // формы рисуется один раз и при прокрутке только едет.
                    .shadow(color: Theme.cardShadow, radius: 12, y: 4)
                    // Кромка — та же, что у панелей над картой (`Theme.edgePanel`).
                    .overlay(shape.strokeBorder(Theme.edgePanel, lineWidth: 1))
            }
    }
}

/// Мишень пальца: 44 pt — не круглое число, а размер подушечки пальца, и в
/// этом приложении по нему уже выровнены точки камер, шестерёнка приборки и
/// строки выбора слоёв. У кнопок закрытия он разъехался: где 44, а где 18–32,
/// потому что каждая задавала размер сама. Растёт ТОЛЬКО область касания —
/// `minWidth`/`minHeight` не трогают ни кегль глифа, ни широкую кнопку, а
/// `contentShape` делает всю мишень нажимаемой, а не только сам глиф.
///
/// За рулём это не придирка к доступности: промах по крестику в баннере
/// означает второй взгляд на экран вместо взгляда на дорогу.
extension View {
    func tapTarget(_ side: CGFloat = 44) -> some View {
        self.frame(minWidth: side, minHeight: side)
            .contentShape(Rectangle())
    }
}

/// Заголовок секции: подпись слева, необязательный акцент справа. Один размер и
/// цвет на все секции — «Километры по дням», «Достижения», список поездок.
struct SectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.rounded(14, .semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Разделитель «дальше — пожизненные цифры»: подпись в разрыве линии. Нужен,
/// чтобы было видно, где кончается власть фильтра периода.
struct LabeledDivider: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            line
            // Одна строка обязательна: узбекское «BUTUN VAQT UCHUN» переносилось
            // на вторую, а линии оставались на высоте первой и висели обрубками.
            Text(title)
                .font(.rounded(11, .semibold))
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
            line
        }
        .padding(.top, 8)
    }

    private var line: some View {
        Rectangle().fill(Theme.stroke).frame(height: 1)
    }
}

/// Круглая кнопка-контрол поверх карты (мой геопоиск, слои и т.п.).
struct CircleControl: View {
    let systemName: String
    var tint: Color = Theme.textPrimary
    var size: CGFloat = Theme.controlSize
    /// Что читает VoiceOver (иконка без текста сама по себе нема).
    var accessibilityLabel: LocalizedStringKey = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CircleControlFace(systemName: systemName, tint: tint, size: size)
                .accessibilityLabel(Text(accessibilityLabel))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Облик круглой кнопки — отдельно от самой кнопки.
///
/// Тот же круг носит `Menu`, а меню не принимает `Button` своим label. Без
/// этого разделения меню в колонке карты пришлось бы рисовать вторым набором
/// тех же градиентов, и «один язык панелей» кончился бы на второй кнопке.
/// Ровно так же в MapScreen отделён `actionLabel` от `actionButton`.
struct CircleControlFace: View {
    let systemName: String
    var tint: Color = Theme.textPrimary
    var size: CGFloat = Theme.controlSize

    var body: some View {
        Image(systemName: systemName)
            .font(.rounded(17, .semibold))
            .foregroundStyle(tint)
            .controlCircle(size: size)
    }
}

extension View {
    /// Подложка круглой кнопки поверх карты — одна на всю колонку.
    ///
    /// Сплошная поверхность, а не стекло: на солнечной карте стекло с белой
    /// иконкой тонуло, и рядом стояли два облика одной роли (стеклянные
    /// слои/ориентация и сплошные «3D»/звук/компас). Теперь любой круг в
    /// колонке — этот модификатор, и третьего облика не появится.
    func controlCircle(size: CGFloat = Theme.controlSize) -> some View {
        frame(width: size, height: size)
            // Тень у круга, а не у глифа поверх него (см. statCard).
            .background {
                Circle().fill(Theme.surface)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            }
            .overlay(Circle().strokeBorder(Theme.edgeControl, lineWidth: 1))
    }
}

/// Подъём над картой — вторая половина той же поверхности, что и кромка.
///
/// Названы только ДВЕ тени из семи, и это не полумера: именно эти две
/// повторяются и означают одну роль. Остальные пять — по одной на место
/// (свечение CTA, полноэкранное предупреждение, маркер), и заводить им токены
/// значило бы завести словарь из синонимов.
extension View {
    /// Панель поверх карты: карточка, бар действий, панель слоёв.
    ///
    /// Только для стеклянных панелей без своей заливки — там тени не от чего
    /// отбрасываться, кроме самой панели. У панели с заливкой бери
    /// `liftedBackground`: `.shadow` на составной вью SwiftUI накладывает на
    /// КАЖДЫЙ вложенный элемент, и цифры, меняющиеся на каждом тике GPS,
    /// получали своё размытие заново.
    func liftPanel() -> some View {
        shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    }

    /// Заливка панели с тенью у ФОРМЫ — та же тень, что у `liftPanel`, но
    /// рисуется один раз и не ложится на текст поверх.
    func liftedBackground<S: Shape, F: ShapeStyle>(_ style: F, in shape: S) -> some View {
        background {
            shape.fill(style)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        }
    }

    /// Ближняя тень акцентной кнопки — та, что даёт объём под пальцем. Ходит
    /// в паре с цветным свечением, поэтому названа отдельно от него.
    func liftAccent() -> some View {
        shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }

    /// Свечение героя — цифры, ради которой экран открывают.
    ///
    /// Тень чёрным на почти чёрном фоне не даёт ничего; цветное свечение в
    /// цвет СОСТОЯНИЯ даёт и объём, и второй намёк на состояние. Радиус
    /// большой и мягкий: это ореол вокруг цифры, а не обводка под ней.
    func glow(_ color: Color, radius: CGFloat = 26) -> some View {
        shadow(color: color.opacity(0.55), radius: radius)
    }

    /// Панель состояния: блок, покрашенный целиком, а не подпись внутри него.
    ///
    /// «Плоско» начиналось именно здесь — состояние жило цветом одной строки
    /// среди одинаково серых соседей. Покрашенный блок с цветной кромкой
    /// виден боковым зрением, и его не надо вычитывать.
    func statePanel(_ color: Color, radius: CGFloat = 20, padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(LinearGradient(colors: [color.opacity(0.20), color.opacity(0.05)],
                                       startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(color.opacity(0.30), lineWidth: 1))
    }
}

/// Премиальный отклик: кнопка мягко пружинит под пальцем.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .motionAnimation(Motion.quick, value: configuration.isPressed)
    }
}

/// Основная акцентная кнопка (CTA). Жёлтая — ОДНА на экран: «Поехали»,
/// «Начать поездку», «Отправить». Второе действие рядом — `SecondaryButton`:
/// две жёлтые подряд (карточка камеры) не говорят, какая главная.
struct PrimaryButton: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    /// По умолчанию — жёлтое главное действие с тёмным текстом. Другой
    /// заливке (danger и т.п.) — белый текст.
    var tint: Color = Theme.action
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.rounded(17, .semibold))
            .foregroundStyle(tint == Theme.action ? Theme.onAction : Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(tint, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Второе действие рядом с главным: та же форма и высота, что у
/// `PrimaryButton`, но без заливки — белая карточка с синим текстом
/// (5,4:1 днём). Форма одна, громкость разная: глаз сразу видит, какая
/// кнопка главная, и обе нажимаются одинаково уверенно.
struct SecondaryButton: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.rounded(17, .semibold))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Красное свечение по краям экрана: превышение у камеры. Видно периферийным
/// зрением — на телефон смотреть не нужно. Один слой с пульсом, тапы пропускает.
struct OverspeedVignette: View {
    /// Пульс уместен у камеры (короткие секунды). На приборке свечение
    /// статично: вечная анимация на экране экономии — GPU-композитинг
    /// часами, ровно то, против чего этот экран построен.
    var pulses = true

    @State private var pulse = false

    var body: some View {
        // Размытая рамка растеризуется ОДИН раз (drawingGroup), а пульсирует
        // только непрозрачность готовой картинки. Прежде пульс менял цвет
        // обводки ПОД blur(24) — и размытие во весь экран пересчитывалось
        // каждый кадр анимации, пока длится превышение
        // (docs/perf_audit_2026-10-07.md). Картинка та же: 0.25…0.55.
        RoundedRectangle(cornerRadius: 44, style: .continuous)
            .strokeBorder(Theme.danger, lineWidth: 22)
            .blur(radius: 24)
            .drawingGroup()
            .opacity(pulses ? (pulse ? 0.55 : 0.25) : 0.4)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onAppear {
                guard pulses else { return }
                withMotion(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .transition(.opacity)
            .accessibilityHidden(true)   // VoiceOver уже читает алерт приближения
    }
}

/// Чип-легенда типа камеры.
struct LegendChip: View {
    let color: Color
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.rounded(10, .bold))
                // Светлый радар — тёмный значок (как на маркере), остальные — белый.
                .foregroundStyle(color == Theme.Types.radar ? Theme.Types.darkGlyph : .white)
                .frame(width: 20, height: 20)
                .background(color, in: Circle())
            Text(text)
                .font(.rounded(12, .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Каскадное появление секций экрана: прозрачность + сдвиг, задержка по индексу.
/// Одноразовая анимация — после появления GPU не нагружает.
struct EntranceModifier: ViewModifier {
    let index: Int
    let appeared: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .motionAnimation(.spring(duration: 0.5, bounce: 0.18).delay(Double(index) * 0.07),
                       value: appeared)
    }
}

extension View {
    func entrance(_ index: Int, _ appeared: Bool) -> some View {
        modifier(EntranceModifier(index: index, appeared: appeared))
    }
}

/// Кольцо рейтинга вождения 0–100: цвет по зоне, заполняется один раз при появлении.
struct RatingRing: View {
    let rating: Int
    var compact: Bool = false
    /// false — кольцо сразу заполнено (для ImageRenderer: onAppear там не приходит).
    var animated: Bool = true
    @State private var shown = false

    init(rating: Int, compact: Bool = false, animated: Bool = true) {
        self.rating = rating
        self.compact = compact
        self.animated = animated
        _shown = State(initialValue: !animated)
    }

    private var color: Color { Theme.score(rating) }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.stroke.opacity(0.7), lineWidth: compact ? 5 : 7)
            Circle()
                .trim(from: 0, to: shown ? Double(rating) / 100 : 0)
                .stroke(color.gradient,
                        style: StrokeStyle(lineWidth: compact ? 5 : 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Без неонового ореола: он остался от тёмной «радарной» темы
                // и на белой карточке читался размытым краем кольца.
            VStack(spacing: 0) {
                Text("\(rating)")
                    .font(.rounded(compact ? 20 : 30, .heavy).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                if !compact {
                    Text("рейтинг")
                        .font(.rounded(10, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .onAppear {
            guard animated else { return }
            withMotion(.spring(duration: 0.9, bounce: 0.15).delay(0.25)) { shown = true }
        }
    }
}

// MARK: - Шэр картинки

/// ShareLink внутри вложенного sheet (Итоги → деталка) на iOS молча не
/// презентуется — шэрим через UIActivityViewController, он работает всегда.
struct ShareImagePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [image],
                                                  applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in dismiss() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Текст для системного «Поделиться» — с ответом, отправил ли человек его
/// («Поделиться прибытием» начинает обновлять ссылку только после отправки).
struct ActivityTextPayload: Identifiable {
    let id = UUID()
    let text: String
}

struct ActivityTextSheet: UIViewControllerRepresentable {
    let text: String
    let onDone: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onDone(completed)
            dismiss()
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Файл для системного «Поделиться» (GPX трека поездки).
struct ShareFilePayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityFileSheet: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in dismiss() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
