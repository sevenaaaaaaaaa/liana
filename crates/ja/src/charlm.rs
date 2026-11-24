//! 字符 4-gram 语言模型：给 Viterbi N-best 做重排（M1.5）。
//!
//! 数据由 `crates/ja/tools/build_charlm.py` 从 Tatoeba 日语语料统计，
//! 只保留出现最多的 20 万个 4-gram，格式见脚本头注释。
//!
//! 分数是「平均每字符成本 ×100」：候选覆盖同一段输入，但输出长度可能不同
//! （日本 2 字 vs にほん 4 字），不归一化会系统性偏向短输出。

use std::collections::HashMap;
use std::sync::OnceLock;

/// 未登录 n-gram 的成本：比任何已存 n-gram 都高，但不足以一票否决。
const UNSEEN: i32 = 1600;

pub struct CharLm {
    order: usize,
    map: HashMap<u64, i16>,
}

impl CharLm {
    pub fn parse(bytes: &[u8]) -> Result<Self, &'static str> {
        if bytes.len() < 9 || &bytes[0..4] != b"JCL1" {
            return Err("magic 不是 JCL1");
        }
        let order = bytes[4] as usize;
        if !(2..=8).contains(&order) {
            return Err("n-gram 阶数超出 2..8");
        }
        let count = u32::from_le_bytes(bytes[5..9].try_into().map_err(|_| "头部截断")?) as usize;
        let need = 9 + count * 10;
        let raw = bytes.get(9..need).ok_or("数据截断")?;
        let mut map = HashMap::with_capacity(count);
        for chunk in raw.chunks_exact(10) {
            let h = u64::from_le_bytes(chunk[0..8].try_into().map_err(|_| "哈希截断")?);
            let c = i16::from_le_bytes([chunk[8], chunk[9]]);
            map.insert(h, c);
        }
        Ok(Self { order, map })
    }

    pub fn embedded() -> &'static CharLm {
        static M: OnceLock<CharLm> = OnceLock::new();
        M.get_or_init(|| {
            CharLm::parse(include_bytes!("../data/charlm.bin")).unwrap_or_else(|e| {
                debug_assert!(false, "内嵌 charlm.bin 损坏：{e}");
                CharLm { order: 4, map: HashMap::new() }
            })
        })
    }

    /// 平均每字符成本 ×100（越小越自然）。
    pub fn score_per_char(&self, text: &str) -> i32 {
        let order = self.order;
        let mut chars: Vec<char> = Vec::with_capacity(text.chars().count() + order);
        for _ in 0..order - 1 {
            chars.push('\0');
        }
        chars.extend(text.chars());
        chars.push('\0');
        if chars.len() < order {
            return UNSEEN;
        }
        let mut sum = 0i64;
        for w in chars.windows(order) {
            let mut h = 0xCBF2_9CE4_8422_2325u64;
            for ch in w {
                h ^= *ch as u64;
                h = h.wrapping_mul(0x0000_0100_0000_01B3);
            }
            sum += self.map.get(&h).copied().unwrap_or(UNSEEN as i16) as i64;
        }
        let n = chars.len() - order + 1;
        ((sum * 100) / n as i64).clamp(i32::MIN as i64, i32::MAX as i64) as i32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_model_scores_natural_text_better() {
        let m = CharLm::embedded();
        let natural = m.score_per_char("私は学校に行きました。");
        let nonsense = m.score_per_char("私は校学にきました行。");
        assert!(natural < nonsense, "natural={natural} nonsense={nonsense}");
    }

    #[test]
    fn bad_magic_is_rejected() {
        assert!(CharLm::parse(b"XXXX").is_err());
    }
}
