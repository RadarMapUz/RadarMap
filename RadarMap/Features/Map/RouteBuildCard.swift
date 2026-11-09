//
//  RouteBuildCard.swift
//  RadarMap
//
//  Карточка хода построения маршрута: стадия, куда, «Отмена», при неудаче —
//  что случилось и «Повторить». Появляется в момент касания, ещё до GPS и сети.
//  Отдельная вью: смены стадий не пересобирают экран карты.
//

import SwiftUI

struct RouteBuildCard: View {
    @Environment(AppEnvironment.self) private var env
    let onRetry: (RouteBuildFlow.Target) -> Void

    private let shape = RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)

    var body: some View {
        Group {
            switch env.route.buildFlow.state {
            case .idle:
                EmptyView()
            case .working(let target, let stage, let slow):
                working(target, stage: stage, slow: slow)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .failed(let target, let failure):
                failed(target, failure: failure)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .motionAnimation(Motion.standard, value: env.route.buildFlow.state)
    }

    private func working(_ target: RouteBuildFlow.Target, stage: RouteBuildFlow.Stage, slow: Bool) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: stage.title)
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.opacity)
                Text(verbatim: slow ? String(localized: "Сеть медленная, ещё немного…") : target.name)
                    .font(.rounded(12, .medium))
                    .foregroundStyle(slow ? Theme.warning : Theme.textSecondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                stages(stage)
            }
            Spacer(minLength: 0)
            Button { env.route.cancelBuild() } label: {
                Text("Отмена")
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .frame(minHeight: Theme.controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(.cancel))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liftedBackground(Theme.surface, in: shape)
        .overlay(shape.strokeBorder(Theme.edgePanel, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// Ход — три отрезка: положение, расчёт, сравнение вариантов.
    private func stages(_ stage: RouteBuildFlow.Stage) -> some View {
        HStack(spacing: 4) {
            ForEach(RouteBuildFlow.Stage.allCases, id: \.self) { step in
                Capsule()
                    .fill(step <= stage ? Theme.accent : Theme.edgePanel)
                    .frame(height: 3)
            }
        }
        .frame(maxWidth: 120)
        .accessibilityHidden(true)
    }

    private func failed(_ target: RouteBuildFlow.Target, failure: RouteBuildFlow.Failure) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.rounded(18, .semibold))
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: failure.title ?? env.route.errorMessage ?? String(localized: "Маршрут не построен"))
                    .font(.rounded(15, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                if let hint = failure.hint {
                    Text(verbatim: hint)
                        .font(.rounded(12, .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if RouteBuildFlow.canRetry(target, failure) {
                Button { onRetry(target) } label: {
                    Text("Повторить")
                        .font(.rounded(15, .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .frame(minHeight: Theme.controlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(.primary))
            }
            Button { env.route.dismissBuildFailure() } label: {
                Image(systemName: "xmark")
                    .font(.rounded(12, .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Theme.background, in: Circle())
                    .tapTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Закрыть"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liftedBackground(Theme.surface, in: shape)
        .overlay(shape.strokeBorder(Theme.edgePanel, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}
