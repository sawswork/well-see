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

/// 検索。意味の近さ（ベクトル）と言葉の一致を合わせて順位をつける。
@MainActor
enum SearchEngine {
    private static var cache: [UUID: (stamp: Int, vector: [Float])] = [:]

    static func search(_ query: String, in items: [Item]) async -> [UUID] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items.map(\.id) }
        let words = q.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let queryVector = await Embedder.shared.vector(for: q)

        struct Scored {
            let id: UUID
            let keyword: Double
            let similarity: Double
        }
        var scored: [Scored] = []
        for item in items {
            let title = item.title.lowercased()
            let rest = [item.summary, item.placeName ?? "", item.address ?? "", item.sourceName, item.genre.label,
                        item.rawText ?? "", item.bodyText].joined(separator: "\n").lowercased()
            var keyword = 0.0
            for word in words {
                if title.contains(word) { keyword += 1.0 } else if rest.contains(word) { keyword += 0.6 }
            }
            keyword /= Double(max(words.count, 1))

            var similarity = 0.0
            if let queryVector, let data = item.embedding {
                let vector: [Float]
                if let hit = cache[item.id], hit.stamp == data.count, hit.vector.count == queryVector.count {
                    vector = hit.vector
                } else {
                    vector = VectorCodec.vector(data)
                    cache[item.id] = (data.count, vector)
                }
                if vector.count == queryVector.count {
                    var dot: Float = 0
                    for i in 0..<vector.count { dot += vector[i] * queryVector[i] }
                    similarity = Double(dot)
                }
            }
            scored.append(Scored(id: item.id, keyword: keyword, similarity: similarity))
        }

        // 意味の近さは、いちばん近いものから少し下までを採る（どれも似た値になりやすいため）。
        let best = scored.map(\.similarity).max() ?? 0
        let floor = best - 0.08
        let kept = scored.filter { $0.keyword > 0 || (best > 0 && $0.similarity >= floor) }
        return kept
            .sorted { ($0.keyword * 0.5 + $0.similarity) > ($1.keyword * 0.5 + $1.similarity) }
            .prefix(60)
            .map(\.id)
    }

    /// 内容が変わったものは作り直させる。
    static func forget(_ id: UUID) {
        cache[id] = nil
    }
}
