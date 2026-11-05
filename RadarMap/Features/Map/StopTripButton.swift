//
//  StopTripButton.swift
//  RadarMap
//
//  «Стоп» в два касания.
//
//  Кнопка завершения поездки стоит в сантиметре от кнопки отметки — самой
//  частой в поездке, той, по которой бьют вслепую большим пальцем на ходу.
//  Промах вправо заканчивал поездку молча и сразу: без вопроса, без отмены,
//  без возможности вернуться. Дальше запись обрывается, а поездка в истории
//  разваливается на куски — ровно то, что человек и увидел в списке своих
//  поездок в Зомин и обратно.
//
//  Поэтому первое касание не завершает, а взводит: кнопка на три секунды
//  становится «Точно?» и ждёт второго. Не дождалась — сама вернулась в
//  исходное. Для того, кто ДЕЙСТВИТЕЛЬНО хочет закончить, цена — одно лишнее
//  касание по кнопке, которая в этот момент стала шире и подписана словом.
//
//  Шире она становится ВЛЕВО: в панели поездки она стоит перед «Отметить»
//  (TripLiveBar), и рост не сдвигает соседку ни на пункт — иначе взведённая
//  кнопка сама ложилась бы под слепой тап, предназначенный «Отметить».
//
//  В панели поездки (02.11) — нейтральная кнопка с красным значком, а не
//  залитый красный квадрат: красный на этой карте — камера, и самый громкий
//  элемент над картой всю поездку был «Стоп». И подтверждение — при ЛЮБОЙ
//  скорости: ниже 20 км/ч он заканчивал поездку с одного касания, а это
//  пробка и светофор — ровно там, где жмут «Отметить» (дизайнер, A.3).
//

import SwiftUI

struct StopTripButton: View {
    @Environment(AppEnvironment.self) private var env
    /// Во всю ширину с подписью — для карточки прибытия. Она встаёт ровно
    /// туда, где была панель поездки с «Радар!», и одно касание по ней
    /// заканчивало поездку: слепой тап, адресованный «Радар!», попадал сюда.
    var wide = false
    var action: () -> Void

    @State private var isArmed = false
    @State private var disarmTask: Task<Void, Never>?

    /// Сколько ждём второго касания. Три секунды — столько, сколько человек
    /// готов держать в голове «я нажал»; дольше — и взведённая кнопка станет
    /// ловушкой для следующего промаха.
    private static let armedSeconds: Duration = .seconds(3)

    /// В панели поездки — всегда: рядом «Отметить», и промах стоя у светофора
    /// не должен заканчивать поездку. Карточка прибытия (`wide`) — на
    /// стоянке без подтверждения: тап там осознанный. Порог — тот же, что у
    /// экрана машины.
    private var needsConfirm: Bool {
        !wide || env.location.speedKmh >= AppConfig.carPlayEndTripConfirmKmh
    }

    var body: some View {
        if wide { wideBody } else { compactBody }
    }

    private var wideBody: some View {
        Button(action: tap) {
            HStack(spacing: 8) {
                Image(systemName: isArmed ? "questionmark" : "stop.fill")
                    .contentTransition(.symbolEffect(.replace))
                (isArmed ? Text("Точно? Нажмите ещё раз") : Text("Завершить поездку"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.rounded(16, .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(Theme.dangerFill, in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        }
        // Взвод и подтверждение звучат по-разному — отклик ведёт сама кнопка.
        .buttonStyle(PressableStyle(.ownFeedback))
        .motionAnimation(.spring(response: 0.3, dampingFraction: 0.8), value: isArmed)
        .accessibilityLabel((isArmed ? Text("Подтвердить завершение поездки") : Text("Завершить поездку")))
        .accessibilityHint(Text("Нажмите дважды: первое касание спрашивает подтверждение"))
        .onDisappear { disarmTask?.cancel() }
    }

    private var compactBody: some View {
        Button(action: tap) {
            HStack(spacing: 6) {
                Image(systemName: isArmed ? "questionmark" : "stop.fill")
                    .font(.rounded(16, .bold))
                    .foregroundStyle(Theme.danger)
                    .contentTransition(.symbolEffect(.replace))
                if isArmed {
                    Text("Точно?")
                        .font(.rounded(15, .heavy))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, isArmed ? 14 : 0)
            .frame(minWidth: 44)
            .frame(height: 44)
            .background(Theme.quietFill,
                        in: RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerControl, style: .continuous)
                .stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .motionAnimation(.spring(response: 0.3, dampingFraction: 0.8), value: isArmed)
        .accessibilityLabel(isArmed ? Text("Подтвердить завершение поездки") : Text("Завершить поездку"))
        .accessibilityHint(Text("Нажмите дважды: первое касание спрашивает подтверждение"))
        .onDisappear { disarmTask?.cancel() }
    }

    private func tap() {
        disarmTask?.cancel()
        guard needsConfirm else {
            isArmed = false
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
            return
        }
        guard isArmed else {
            isArmed = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            disarmTask = Task {
                // Ошибка sleep — только отмена задачи; что делать после неё, решает проверка ниже.
                try? await Task.sleep(for: Self.armedSeconds)
                guard !Task.isCancelled else { return }
                isArmed = false
            }
            return
        }
        isArmed = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        action()
    }
}
