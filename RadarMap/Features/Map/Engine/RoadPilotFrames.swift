// Автоматический черновик: приблизительная Web Mercator привязка по URL.
// Это не калибровка и не данные для маршрутизации.
// Только отладочная сборка: экран сверки («Пилот дорог») есть лишь в DEBUG.
#if DEBUG
import Foundation
struct RoadPilotFrame: Identifiable {
    let id: Int
    let imageName: String
    let latitude, longitude, north, south, west, east: Double
    let empty: Bool
    let referenceAligned: Bool
    static let all: [RoadPilotFrame] = [
        .init(id: 0, imageName: "road-pilot-a67fe5575608f8dd", latitude: 41.350634040446906, longitude: 69.23769259622577, north: 41.35190856220945, south: 41.349359493732265, west: 69.23425936868671, east: 69.24112582376483, empty: false, referenceAligned: true),
        .init(id: 1, imageName: "road-pilot-69fa6bcf67fd0187", latitude: 41.350627999999986, longitude: 69.2442, north: 41.3519025218808, south: 41.3493534531671, west: 69.24076677246094, east: 69.24763322753907, empty: false, referenceAligned: false),
        .init(id: 2, imageName: "road-pilot-397d82e14c9f58bc", latitude: 41.35061994606991, longitude: 69.23178600727081, north: 41.3518944681084, south: 41.34934539907934, west: 69.22835277973175, east: 69.23521923480988, empty: false, referenceAligned: true),
        .init(id: 3, imageName: "road-pilot-a8f9e2e4925ebd28", latitude: 41.350627999999986, longitude: 69.25011999999998, north: 41.3519025218808, south: 41.3493534531671, west: 69.24668677246092, east: 69.25355322753904, empty: false, referenceAligned: false),
        .init(id: 4, imageName: "road-pilot-7db6334b7a6388db", latitude: 41.350627999999986, longitude: 69.22644, north: 41.3519025218808, south: 41.3493534531671, west: 69.22300677246093, east: 69.22987322753906, empty: false, referenceAligned: false),
        .init(id: 5, imageName: "road-pilot-c1bd2f67f38aa287", latitude: 41.352847, longitude: 69.23828000000003, north: 41.35412147843747, south: 41.3515724966102, west: 69.23484677246097, east: 69.2417132275391, empty: false, referenceAligned: false),
        .init(id: 6, imageName: "road-pilot-e964d7bde2dc0659", latitude: 41.352847, longitude: 69.2442, north: 41.35412147843747, south: 41.3515724966102, west: 69.24076677246094, east: 69.24763322753907, empty: false, referenceAligned: false),
        .init(id: 7, imageName: "road-pilot-4329f24f8e6be424", latitude: 41.350627999999986, longitude: 69.25603999999998, north: 41.3519025218808, south: 41.3493534531671, west: 69.25260677246092, east: 69.25947322753905, empty: false, referenceAligned: false),
        .init(id: 8, imageName: "road-pilot-0a9e8be7f16beb38", latitude: 41.352847, longitude: 69.23236, north: 41.35412147843747, south: 41.3515724966102, west: 69.22892677246094, east: 69.23579322753906, empty: false, referenceAligned: false),
        .init(id: 9, imageName: "road-pilot-452f2c8d2b852e80", latitude: 41.352847, longitude: 69.25011999999998, north: 41.35412147843747, south: 41.3515724966102, west: 69.24668677246092, east: 69.25355322753904, empty: false, referenceAligned: false),
        .init(id: 10, imageName: "road-pilot-2ae04c0ba362ecbe", latitude: 41.350627999999986, longitude: 69.22051999999996, north: 41.3519025218808, south: 41.3493534531671, west: 69.2170867724609, east: 69.22395322753903, empty: false, referenceAligned: false),
        .init(id: 11, imageName: "road-pilot-069034aa2e923537", latitude: 41.352847, longitude: 69.22644, north: 41.35412147843747, south: 41.3515724966102, west: 69.22300677246093, east: 69.22987322753906, empty: false, referenceAligned: false),
        .init(id: 12, imageName: "road-pilot-c16b24001d106c32", latitude: 41.355063986654834, longitude: 69.23770868947986, north: 41.35633842168647, south: 41.35378952667063, west: 69.2342754619408, east: 69.24114191701892, empty: false, referenceAligned: true),
        .init(id: 13, imageName: "road-pilot-ff1c791bd291eee2", latitude: 41.35286713413454, longitude: 69.25549282936095, north: 41.35414161217782, south: 41.35159263113894, west: 69.25205960182188, east: 69.25892605690001, empty: false, referenceAligned: true),
        .init(id: 14, imageName: "road-pilot-9fed6a209c1b64dc", latitude: 41.350627999999986, longitude: 69.26195999999999, north: 41.3519025218808, south: 41.3493534531671, west: 69.25852677246093, east: 69.26539322753905, empty: false, referenceAligned: false),
        .init(id: 15, imageName: "road-pilot-046047dba7968445", latitude: 41.355066, longitude: 69.2442, north: 41.35634043499221, south: 41.35379154005521, west: 69.24076677246094, east: 69.24763322753907, empty: false, referenceAligned: false),
        .init(id: 16, imageName: "road-pilot-e98f02bb064c1423", latitude: 41.355066, longitude: 69.23236, north: 41.35634043499221, south: 41.35379154005521, west: 69.22892677246094, east: 69.23579322753906, empty: false, referenceAligned: false),
        .init(id: 17, imageName: "road-pilot-2878fcf9e452222a", latitude: 41.355066, longitude: 69.25011999999998, north: 41.35634043499221, south: 41.35379154005521, west: 69.24668677246092, east: 69.25355322753904, empty: true, referenceAligned: false),
        .init(id: 18, imageName: "road-pilot-11a255cfc86b9b74", latitude: 41.352847, longitude: 69.22051999999996, north: 41.35412147843747, south: 41.3515724966102, west: 69.2170867724609, east: 69.22395322753903, empty: false, referenceAligned: false),
        .init(id: 19, imageName: "road-pilot-36962c05c884660f", latitude: 41.355066, longitude: 69.22644, north: 41.35634043499221, south: 41.35379154005521, west: 69.22300677246093, east: 69.22987322753906, empty: false, referenceAligned: false),
        .init(id: 20, imageName: "road-pilot-727a527ed5508ad3", latitude: 41.350627999999986, longitude: 69.21459999999999, north: 41.3519025218808, south: 41.3493534531671, west: 69.21116677246093, east: 69.21803322753905, empty: false, referenceAligned: false),
        .init(id: 21, imageName: "road-pilot-7484a2de26c9cdb9", latitude: 41.352847, longitude: 69.26195999999999, north: 41.35412147843747, south: 41.3515724966102, west: 69.25852677246093, east: 69.26539322753905, empty: false, referenceAligned: false),
        .init(id: 22, imageName: "road-pilot-3b2a78cbc7c5a432", latitude: 41.355066, longitude: 69.25603999999998, north: 41.35634043499221, south: 41.35379154005521, west: 69.25260677246092, east: 69.25947322753905, empty: false, referenceAligned: false),
        .init(id: 23, imageName: "road-pilot-61729b8e9b5484b5", latitude: 41.357278960170234, longitude: 69.23769527843478, north: 41.35855335183354, south: 41.3560045435541, west: 69.23426205089572, east: 69.24112850597385, empty: false, referenceAligned: true),
        .init(id: 24, imageName: "road-pilot-5679017be972ce62", latitude: 41.35731117258918, longitude: 69.24364478273392, north: 41.358585563621766, south: 41.356036756603764, west: 69.24021155519486, east: 69.24707801027299, empty: false, referenceAligned: true),
        .init(id: 25, imageName: "road-pilot-ff968695828a62a9", latitude: 41.35062195955253, longitude: 69.26731941831585, north: 41.3518964815516, south: 41.349347412601375, west: 69.26388619077679, east: 69.27075264585491, empty: false, referenceAligned: true),
        .init(id: 26, imageName: "road-pilot-0e8813e66142daf6", latitude: 41.357285, longitude: 69.23236, north: 41.35855939154504, south: 41.35601058350213, west: 69.22892677246094, east: 69.23579322753906, empty: false, referenceAligned: false),
        .init(id: 27, imageName: "road-pilot-21022c196031d25c", latitude: 41.35728097344688, longitude: 69.24956746494291, north: 41.35855536507077, south: 41.356006556870184, west: 69.24613423740385, east: 69.25300069248198, empty: false, referenceAligned: true),
        .init(id: 28, imageName: "road-pilot-3018d6ce0fbd26ba", latitude: 41.35508412010367, longitude: 69.21993796064373, north: 41.3563585547411, south: 41.353809660513654, west: 69.21650473310467, east: 69.2233711881828, empty: false, referenceAligned: true),
        .init(id: 29, imageName: "road-pilot-54c8e6fb9478f3eb", latitude: 41.352847, longitude: 69.21459999999999, north: 41.35412147843747, south: 41.3515724966102, west: 69.21116677246093, east: 69.21803322753905, empty: false, referenceAligned: false)
    ]
}
#endif
