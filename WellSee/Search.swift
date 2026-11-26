import Foundation
import NaturalLanguage

/// 文章をベクトル（数字の並び）にする。端末内の日本語モデルを使い、通信はしない。
/// モデルが用意できない端末では nil を返し、検索は言葉の一致だけで動く。
actor Embedder {
    static let shared = Embedder()

    private var model: NLContextualEmbedding?
    private var prepared = false

    /// モデルを読み込む。必要なら端末がモデルを取りに行く（一度だけ）。
    func prepare() async {
        guard !prepared else { return }
        prepared = true
        guard let candidate = NLContextualEmbedding(language: .japanese) else { return }
        if !candidate.hasAvailableAssets {
            _ = try? await candidate.requestAssets()
        }
        guard candidate.hasAvailableAssets, (try? candidate.load()) != nil else { return }
        model = candidate
    }

    /// 長さ1にそろえたベクトル。
    func vector(for text: String) async -> [Float]? {
        await prepare()
        guard let model else { return nil }
        let input = String(text.prefix(600))
        guard !input.isEmpty, let result = try? model.embeddingResult(for: input, language: .japanese) else {
            return nil
        }
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: input.startIndex..<input.endIndex) { vector, _ in
            if vector.count == sum.count {
                for i in 0..<vector.count { sum[i] += vector[i] }
                count += 1
            }
            return true
        }
        guard count > 0 else { return nil }
        var norm = 0.0
        for i in 0..<sum.count {
            sum[i] /= Double(count)
            norm += sum[i] * sum[i]
        }
        norm = norm.squareRoot()
        guard norm > 0 else { return nil }
        return sum.map { Float($0 / norm) }
    }
}

enum VectorCodec {
    static func data(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func vector(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        var out = [Float](repeating: 0, count: count)
        _ = out.withUnsafeMutableBufferPointer { data.copyBytes(to: $0) }
        return out
    }
}

/// 検索。
/// まず言葉の一致（題名・分類・関連語・要約など、中身を表す欄だけ）で探す。
/// そのうえで、意味がはっきり近いものだけをベクトルで足す。
/// ページ全体の文字（メニューや広告を含む）は見ない。無関係なものが混ざる原因になるため。
@MainActor
enum SearchEngine {
    private static var cache: [UUID: [Float]] = [:]

    static func search(_ query: String, in items: [Item]) async -> [UUID] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items.map(\.id) }
        let words = q.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let queryVector = await Embedder.shared.vector(for: q)

        struct Scored {
            let id: UUID
            var keyword: Double
            var similarity: Double?
            var z: Double = 0
        }
        var scored: [Scored] = []
        for item in items {
            // 欄ごとの重み。上にあるほど「その内容そのもの」を表す。
            var fields: [(String, Double)] = [
                (item.title, 1.0), (item.category, 0.9), (item.keywords, 0.9), (item.genre.label, 0.8),
                (item.placeName ?? "", 0.8), (item.author, 0.7), (item.sourceName, 0.7),
                (item.summary, 0.6), (item.points, 0.6), (item.address ?? "", 0.5), (item.rawText ?? "", 0.5),
            ]
            // 自分の画像やメモは、読み取った文字そのものが中身。
            if item.url == nil { fields.append((item.bodyText, 0.5)) }
            let lowered = fields.map { ($0.0.lowercased(), $0.1) }
            var total = 0.0
            var allHit = true
            for word in words {
                let best = lowered.filter { $0.0.contains(word) }.map(\.1).max() ?? 0
                if best == 0 { allHit = false }
                total += best
            }
            // 複数の言葉は、すべて当たったものだけを一致とみなす。
            let keyword = allHit ? total / Double(max(words.count, 1)) : 0

            var similarity: Double?
            if let queryVector, let data = item.embedding {
                let vector: [Float]
                if let hit = cache[item.id], hit.count == queryVector.count {
                    vector = hit
                } else {
                    vector = VectorCodec.vector(data)
                    cache[item.id] = vector
                }
                if vector.count == queryVector.count {
                    var dot: Float = 0
                    for i in 0..<vector.count { dot += vector[i] * queryVector[i] }
                    similarity = Double(dot)
                }
            }
            scored.append(Scored(id: item.id, keyword: keyword, similarity: similarity))
        }

        // 意味の近さは、全体の中でどれだけ飛び抜けているか（偏差）で見る。
        // 値そのものはどれも似通うので、平均からの離れ具合を使う。
        let values = scored.compactMap(\.similarity)
        if values.count >= 6 {
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
            let deviation = variance.squareRoot()
            if deviation > 0.0005 {
                for i in scored.indices {
                    if let s = scored[i].similarity { scored[i].z = (s - mean) / deviation }
                }
            }
        }

        let keywordHits = scored.filter { $0.keyword > 0 }
            .sorted { ($0.keyword, $0.z) > ($1.keyword, $1.z) }
        // 言葉で当たったものがあるときは、意味だけで足すのは飛び抜けて近いものに限る。
        let threshold = keywordHits.isEmpty ? 1.3 : 1.9
        let limit = keywordHits.isEmpty ? 8 : 4
        let semanticOnly = scored.filter { $0.keyword == 0 && $0.z >= threshold }
            .sorted { $0.z > $1.z }
            .prefix(limit)
        return (keywordHits + semanticOnly).prefix(60).map(\.id)
    }

    /// 内容が変わったものは作り直させる。
    static func forget(_ id: UUID) {
        cache[id] = nil
    }
}
