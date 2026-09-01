import CoreLocation
import Foundation

/// Что именно сейчас стоит в locationd: набор геозон вокруг камер.
///
/// Существует ради одной проверки — «а изменилось ли вообще что-нибудь».
/// Пересборка геозон стоит сорока синхронных походов в locationd на главном
/// потоке, и до появления хука доставки отметок это случалось редко (ретайл
/// раз в 300–1500 м). Теперь пересборку зовёт каждый опрос сервера, который
/// принёс изменение — а изменением считается и чужая отметка за пять
/// километров, которая в двадцатку ближайших не попадает. Без этой проверки
/// хук доставки оплачивался бы батареей в тихом фоне.
///
/// Сравниваем МНОЖЕСТВОМ, а не списком: `nearest` отсортирован по расстоянию,
/// и на ходу те же двадцать камер меняются местами каждый фикс. Для геозон
/// порядок не значит ничего.
struct GeofencePlan: Equatable {
    struct Anchor: Hashable {
        let id: Int
        let lat: Double
        let lon: Double
    }

    private var armed: Set<Anchor> = []
    private var radius: CLLocationDistance = 0

    var isEmpty: Bool { armed.isEmpty }

    static func anchors(_ cameras: [Camera]) -> Set<Anchor> {
        Set(cameras.map { Anchor(id: $0.id, lat: $0.lat, lon: $0.lon) })
    }

    /// Отметку могут уточнить (amend): id тот же, координата другая. Поэтому в
    /// отпечаток входит координата, а не только id.
    func needsRearm(cameras: [Camera], radius: CLLocationDistance) -> Bool {
        self.radius != radius || armed != Self.anchors(cameras)
    }

    mutating func arm(cameras: [Camera], radius: CLLocationDistance) {
        armed = Self.anchors(cameras)
        self.radius = radius
    }

    mutating func disarm() {
        armed = []
        radius = 0
    }
}
