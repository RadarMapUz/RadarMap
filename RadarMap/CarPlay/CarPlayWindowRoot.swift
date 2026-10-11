//
//  CarPlayWindowRoot.swift
//  RadarMap
//
//  Корень окна машины. Ставится в window.rootViewController ОДИН раз — в
//  didConnect, как в примере Apple, — и больше не меняется; меняется только
//  содержимое внутри (setContent).
//
//  Почему так, видно по журналам хоста шаблонов CarPlay 11.10:
//  • 2.2.5: сторож пересоздавал хост через `window.rootViewController = …`.
//    Хост CarPlay продолжал показывать слой прежнего корня — на экране стоял
//    один кадр, а кнопки шаблона жили («окно застыло»).
//  • 2.2.6: корень ставился не при подключении, а позже, в
//    sceneWillEnterForeground. Хост решал, что видимого окна у приложения
//    нет: «Removing visibility view for pid …, not considered visible» и «Not
//    installing presentation view» — экран машины пустой, без карты и бара.
//  Постоянный корень и сменное содержимое закрывают оба случая: слой окна,
//  который показывает машина, один на всё подключение.
//

import SwiftUI
import UIKit

final class CarPlayWindowRoot: UIViewController {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    /// Что сейчас внутри (хост SwiftUI экрана машины или плитки панели).
    private(set) var content: UIViewController?

    override func loadView() {
        let view = UIView()
        view.backgroundColor = UIColor(Theme.background)
        self.view = view
    }

    /// Поставить новое содержимое вместо прежнего; nil — пусто (фон).
    func setContent(_ controller: UIViewController?) {
        if let old = content {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        content = controller
        guard let controller else { return }
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
    }
}
