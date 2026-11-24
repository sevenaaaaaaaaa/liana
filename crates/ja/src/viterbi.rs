//! 假名 → 汉字：词格 + 词性 bigram 的 Viterbi N-best。
//!
//! 每个节点是一条词典词（读音命中输入片段），边成本 = 词成本 + 连接矩阵成本。
//! 没有词典命中的位置一定有一个单假名兜底节点（UNK 词性），所以任何输入都有路径，
//! 最坏情况原样输出假名。
//!
//! N-best 用「每个位置保留 K 条最优路径」实现：K 小（默认 5）时复杂度与 1-best 同阶。

use crate::dict::Dictionary;
use crate::matrix::Matrix;
use crate::pos;

/// 兜底单假名节点的成本：比最冷僻的词典词（约 1530）略低，
/// 保证「有词可用时先用词」，同时不至于让未知假名拖垮整句。
const FALLBACK_COST: i32 = 1300;

#[derive(Clone, Copy)]
struct Node<'a> {
    start: usize,
    end: usize,
    surface: &'a str,
    pos: u8,
    cost: i32,
}

#[derive(Clone, Copy)]
struct Path {
    cost: i32,
    node: usize,
    prev_rank: usize,
}

pub struct Conversion {
    pub text: String,
    pub cost: i32,
}

pub fn convert(kana: &str, dict: &Dictionary, matrix: &Matrix, k: usize) -> Vec<Conversion> {
    let chars: Vec<char> = kana.chars().collect();
    let n = chars.len();
    if n == 0 {
        return Vec::new();
    }
    let k = k.clamp(1, 8);

    let mut offsets = Vec::with_capacity(n + 1);
    let mut byte = 0usize;
    offsets.push(0);
    for ch in &chars {
        byte += ch.len_utf8();
        offsets.push(byte);
    }

    let max_len = dict.max_len().min(n);
    let mut nodes: Vec<Node> = Vec::new();
    let mut at_start: Vec<Vec<usize>> = vec![Vec::new(); n];

    for i in 0..n {
        let mut seen: Vec<&str> = Vec::new();
        for len in 1..=max_len {
            if i + len > n {
                break;
            }
            let key = &kana[offsets[i]..offsets[i + len]];
            let Some(words) = dict.lookup(key) else { continue };
            for w in words {
                if seen.iter().any(|s| *s == &*w.surface) {
                    continue;
                }
                let id = nodes.len();
                nodes.push(Node {
                    start: i,
                    end: i + len,
                    surface: &w.surface,
                    pos: w.pos,
                    cost: w.cost,
                });
                at_start[i].push(id);
                seen.push(&w.surface);
            }
        }
        let ch = &kana[offsets[i]..offsets[i + 1]];
        if !seen.iter().any(|s| *s == ch) {
            let id = nodes.len();
            nodes.push(Node { start: i, end: i + 1, surface: ch, pos: pos::UNK, cost: FALLBACK_COST });
            at_start[i].push(id);
        }
    }

    let mut best: Vec<Vec<Path>> = vec![Vec::new(); n + 1];
    best[0].push(Path { cost: 0, node: usize::MAX, prev_rank: 0 });

    for i in 0..n {
        best[i].sort_by_key(|p| p.cost);
        best[i].truncate(k);
        for &id in &at_start[i] {
            let node = nodes[id];
            let mut cands: Vec<Path> = Vec::with_capacity(best[i].len());
            for (rank, prev) in best[i].iter().enumerate() {
                let prev_pos = if i == 0 { pos::BOS } else { nodes[prev.node].pos };
                let cost = prev.cost + node.cost + matrix.cost(prev_pos, node.pos);
                cands.push(Path { cost, node: id, prev_rank: rank });
            }
            cands.sort_by_key(|p| p.cost);
            cands.truncate(k);
            best[node.end].extend(cands);
        }
    }

    best[n].sort_by_key(|p| p.cost);
    best[n].truncate(k);
    let mut finals: Vec<(i32, Path)> = best[n]
        .iter()
        .map(|p| (p.cost + matrix.cost(nodes[p.node].pos, pos::EOS), *p))
        .collect();
    finals.sort_by_key(|x| x.0);

    let mut out: Vec<Conversion> = Vec::new();
    for (cost, path) in finals {
        let text = rebuild(path, &best, &nodes);
        if text.is_empty() || out.iter().any(|c| c.text == text) {
            continue;
        }
        out.push(Conversion { text, cost });
        if out.len() >= k {
            break;
        }
    }
    out
}

fn rebuild(mut path: Path, best: &[Vec<Path>], nodes: &[Node]) -> String {
    let mut parts: Vec<&str> = Vec::new();
    let mut guard = 0usize;
    while path.node != usize::MAX {
        let node = &nodes[path.node];
        parts.push(node.surface);
        if node.start == 0 {
            break;
        }
        let Some(prev) = best[node.start].get(path.prev_rank) else { break };
        path = *prev;
        guard += 1;
        if guard > 4096 {
            break;
        }
    }
    parts.reverse();
    parts.concat()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 走完整管线（Viterbi 20-best + 字符 n-gram 重排），与引擎实际调用一致。
    fn conv(kana: &str) -> Vec<Conversion> {
        crate::convert_kana(kana)
    }

    #[test]
    fn core_words_convert() {
        assert_eq!(conv("にほん")[0].text, "日本");
        assert_eq!(conv("がっこう")[0].text, "学校");
        assert_eq!(conv("とうきょう")[0].text, "東京");
        assert_eq!(conv("たべました")[0].text, "食べました");
        assert_eq!(conv("いきました")[0].text, "行きました");
    }

    #[test]
    fn greeting_prefers_kana_spelling() {
        assert_eq!(conv("こんにちわ")[0].text, "こんにちは");
    }

    #[test]
    fn katakana_reading_keeps_katakana_surface() {
        assert_eq!(conv("ゔぁいおりん")[0].text, "ヴァイオリン");
    }

    #[test]
    fn unknown_kana_is_preserved() {
        assert_eq!(conv("ぴゃぴゃぴゃ")[0].text, "ぴゃぴゃぴゃ");
    }

    #[test]
    fn particles_stay_kana() {
        for p in ["は", "が", "を", "に", "で", "と", "も", "の", "へ"] {
            assert_eq!(conv(p)[0].text, p, "助词 {p} 不该被同音汉字顶掉");
        }
    }

    #[test]
    fn n_best_has_multiple_paths_for_ambiguous_reading() {
        let c = conv("こう");
        assert!(c.len() >= 2, "こう 应有多条候选：{:?}", c.iter().map(|x| &x.text).collect::<Vec<_>>());
    }

    #[test]
    fn empty_input_is_empty() {
        assert!(conv("").is_empty());
    }

    #[test]
    fn sentence_smoke() {
        let c = conv("わたしはがっこうにいきました。");
        assert!(c[0].text.starts_with("私は学校に"), "{}", c[0].text);
        assert!(c[0].text.ends_with('。'));
    }
}
