//
//  DetourOfferCard.swift
//  RadarMap
//
//  «Быстрее на 8 мин — объехать?» — предложение объезда пробки на телефоне.
//
//  Решение — водителя, не наше: голос сказал (RouteService.onDetourOffer),
//  карточка ждёт касания и сама гаснет через `detourOfferSeconds` — без ответа
//  остаёмся на своём пути. То же предложение в машине — баннером CarPlay;
//  ответ в одном месте снимает его в другом (одно состояние в RouteService).
//

import SwiftUI

struct DetourOfferCard: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if let offer = env.route.detourOffer {
            SolidPanel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        IconBadge(symbol: "arrow.triangle.branch", tint: Theme.success, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(offer.title)
                                .font(.rounded(17, .bold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(offer.subtitle)
                                .font(.rounded(13, .medium))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 10) {
                        SecondaryButton(title: "Остаться") { env.route.declineDetour() }
                        PrimaryButton(title: "Объехать", systemImage: "arrow.triangle.turn.up.right.diamond.fill") {
                            env.route.acceptDetour(cameras: env.cameras.cameras)
                        }
                    }
                }
                .padding(14)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(offer.id)
        }
    }
}
