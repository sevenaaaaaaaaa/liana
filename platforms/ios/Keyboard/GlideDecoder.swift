import Foundation

enum GlideDecoder {
    static func decode(points: [CGPoint], centers: [String: CGPoint], lexicon: MobileLexicon, english: Bool) -> [MobileWord] {
        guard points.count >= 3, let start = points.first, let end = points.last,
              let first = nearest(start, centers), let last = nearest(end, centers),
              let firstLetter = first.first, let lastLetter = last.first else { return [] }
        let actual = samples(points, count: 32)
        let pitch = max(18, abs((centers["w"]?.x ?? 40) - (centers["q"]?.x ?? 10)))
        return lexicon.glideWords(first: firstLetter, last: lastLetter, english: english).compactMap { word -> (MobileWord, Double)? in
            let shape = word.code.compactMap { centers[String($0)] }
            guard shape.count >= 2 else { return nil }
            let ideal = samples(shape, count: 32)
            let distance = zip(actual, ideal).reduce(0.0) { result, pair in result + hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y) / pitch } / 32
            let score = distance - log(Double(max(1, word.frequency))) * 0.025
            return (word, score)
        }.sorted { $0.1 < $1.1 }.prefix(9).map(\.0)
    }
    private static func nearest(_ point: CGPoint, _ centers: [String: CGPoint]) -> String? {
        centers.min { hypot($0.value.x-point.x,$0.value.y-point.y) < hypot($1.value.x-point.x,$1.value.y-point.y) }?.key
    }
    private static func samples(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard let first = points.first, points.count > 1 else { return Array(repeating: points.first ?? .zero, count: count) }
        var lengths = [0.0]
        for i in 1..<points.count { lengths.append(lengths.last! + hypot(points[i].x-points[i-1].x,points[i].y-points[i-1].y)) }
        let total = lengths.last!
        guard total > 0 else { return Array(repeating: first, count: count) }
        var segment = 1
        return (0..<count).map { index in
            let distance = total * Double(index) / Double(count-1)
            while segment < points.count-1 && lengths[segment] < distance { segment += 1 }
            let amount = (distance-lengths[segment-1]) / max(0.001,lengths[segment]-lengths[segment-1])
            return CGPoint(x: points[segment-1].x+(points[segment].x-points[segment-1].x)*amount,
                           y: points[segment-1].y+(points[segment].y-points[segment-1].y)*amount)
        }
    }
}
