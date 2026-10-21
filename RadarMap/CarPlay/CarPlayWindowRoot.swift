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

import CarPlay
import SwiftUI
import UIKit

final class CarPlayWindowRoot: UIViewController {
    /// Снос без прыжка на актор — тот же обход бага рантайма, что у моделей.
    nonisolated deinit {}

    /// Что сейчас внутри (хост SwiftUI экрана машины или плитки панели).
    private(set) var content: UIViewController?

    /// Отступы, которые занимают кнопки карты («Радар!», +, −, осмотр/«к себе»):
    /// разница между окном и `mapButtonSafeAreaLayoutGuide`. SwiftUI внутри
    /// окна этот гайд не видит — без него HUD у правого края ложился бы под
    /// кнопки. Зовётся только на изменение.
    var onMapButtonInsets: ((UIEdgeInsets) -> Void)?
    private var lastButtonInsets: UIEdgeInsets?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let window = view.window as? CPWindow else { return }
        let guide = window.mapButtonSafeAreaLayoutGuide.layoutFrame
        let bounds = view.bounds
        guard guide.width > 0, guide.height > 0 else { return }
        let insets = UIEdgeInsets(top: max(0, guide.minY - bounds.minY),
                                  left: max(0, guide.minX - bounds.minX),
                                  bottom: max(0, bounds.maxY - guide.maxY),
                                  right: max(0, bounds.maxX - guide.maxX))
        guard insets != lastButtonInsets else { return }
        lastButtonInsets = insets
        onMapButtonInsets?(insets)
    }

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
