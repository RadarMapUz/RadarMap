//
//  ShareCardShell.swift
//  RadarMap
//
//  Каркас шеринг-карточки: фирменная шапка RadarMap, центральный контент,
//  футер. Заполняют TripShareCard (поездка), PeriodShareCard (период) и
//  AchievementShareCard (достижение).
//
//  Два формата, потому что делятся по-разному: лента (4:5) и сторис (9:16).
//  Сторис — не другая вёрстка, а тот же макет в более высоком поле: иначе
//  пришлось бы поддерживать две карточки на каждую тему и они бы разъехались.
//

import SwiftUI

/// Куда пойдёт картинка. Размеры — в точках рендера; ImageRenderer со scale 2
/// даёт привычные 1080×1350 и 1080×1920.
enum ShareFormat: String, CaseIterable, Identifiable {
    case feed, story

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feed:  return String(localized: "Лента")
        case .story: return String(localized: "Сторис")
        }
    }

    var symbol: String {
        switch self {
        case .feed:  return "square"
        case .story: return "rectangle.portrait"
        }
    }

    var size: CGSize {
        switch self {
        case .feed:  return CGSize(width: 540, height: 675)
        case .story: return CGSize(width: 540, height: 960)
        }
    }
}

struct ShareCardShell<Content: View>: View {
    /// Подпись справа в шапке («дата» / «Мои итоги»).
    let subtitle: String
    var format: ShareFormat = .feed
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Theme.accent)
                Text("RadarMap")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text(subtitle)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 32)
            .padding(.top, 32)

            content

            Text("Карта камер и навигатор Узбекистана")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.vertical, 14)
                // В сторис нижняя треть перекрыта интерфейсом соцсети —
                // поднимаем подпись, иначе она уедет под кнопку «Отправить».
                .padding(.bottom, format == .story ? 96 : 0)
        }
        .frame(width: format.size.width, height: format.size.height)
        .background(
            ZStack {
                Theme.background
                RadialGradient(colors: [Theme.accent.opacity(0.14), .clear],
                               center: .center, startRadius: 40, endRadius: 380)
            }
        )
        // Карточка — картинка для чужих лент, и она ТЁМНАЯ всегда: белый
        // текст в ней местами задан прямо, а ImageRenderer рисует вне
        // окружения приложения (по умолчанию в светлой схеме), и адаптивные
        // токены Theme дали бы тёмный текст на тёмной карточке.
        .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// Метрики скруглённой плиткой в полях карточки (материалы в ImageRenderer
    /// не рендерятся — только простые заливки).
    func shareMetricsTile() -> some View {
        self.padding(.vertical, 16)
            .background(.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1))
            .padding(.horizontal, 16)
    }
}

/// Карта на шеринг-карточке: размер задаёт КОНТЕЙНЕР, картинка живёт в
/// `overlay` и обрезается по нему.
///
/// Прямой путь — `Image.resizable().aspectRatio(.fill).frame(...).clipShape(...)` —
/// на деле не обрезает: при `.fill` картинка (1032 pt шириной) вылезает за
/// рамку, и в вертикальном формате карта уезжала за края карточки, а шапка и
/// футер выдавливались наружу. Здесь `Color.clear` фиксирует прямоугольник
/// первым, поэтому обрезать уже нечему сопротивляться.
struct ShareMapFrame: View {
    let image: UIImage
    let height: CGFloat
    var corner: CGFloat = 18

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1))
    }
}
