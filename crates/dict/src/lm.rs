//! 字级搭配模型（整句解码的上下文打分）。
//!
//! 每条是 2～4 个字的片段及其搭配分（越高越像真实语料里的连续片段）。整句解码时，
//! 在词与词的交界处取「上文末尾 1～2 个字 + 下一个词开头 1～2 个字」能匹配到的最高分，
//! 让「什么时候到的」压过「什么时候道德」、「尽快回复你」压过「尽快恢复你」。
//!
//! 文件格式 LMC2（小端），按块压缩，加载后不再展开：
//! `"LMC2"` | u32 字数 | 字表（u32 码点 × 字数，升序）| u32 条数 | u32 块数
//! | 块索引（u64 块首键 + u32 块内字节偏移）× 块数 | u32 数据字节数 | 数据
//!
//! - 键：每个字取字表下标 + 1 占 14 位，第一个字在最高位，不足 4 个字的低位补 0；整体升序；
//! - 每块最多 `BLOCK` 条：块首键记在索引里，块内每条是「与上一条键的差（LEB128 变长整数，块首记 0）+ 1 字节分」；
//! - 分：`(搭配分 - VALUE_BASE) × 10` 量化到 0～255。

use std::collections::HashMap;

use crate::DictError;

const MAGIC: &[u8; 4] = b"LMC2";
/// 单个键最多几个字。
pub const MAX_KEY_CHARS: usize = 4;
const SLOT_BITS: u32 = 14;
const BLOCK: usize = 128;
/// 量化基准：octagram 里低于 8 分的搭配不起作用（与解码器的阈值一致）。
const VALUE_BASE: f32 = 8.0;

#[derive(Debug, Default)]
pub struct Collocations {
    index: HashMap<char, u16>,
    chars: Vec<char>,
    count: usize,
    /// (块首键, 块在 data 里的偏移)
    blocks: Vec<(u64, u32)>,
    data: Vec<u8>,
}

impl Collocations {
    /// 由 (片段, 分) 构建；超长、字数不足 2 或字表放不下的片段跳过。
    pub fn build(entries: impl IntoIterator<Item = (String, f32)>) -> Self {
        let entries: Vec<(Vec<char>, f32)> = entries
            .into_iter()
            .map(|(s, v)| (s.chars().collect::<Vec<_>>(), v))
            .filter(|(c, _)| (2..=MAX_KEY_CHARS).contains(&c.len()))
            .collect();
        let mut chars: Vec<char> = entries
            .iter()
            .flat_map(|(c, _)| c.iter().copied())
            .collect();
        chars.sort_unstable();
        chars.dedup();
        chars.truncate((1 << SLOT_BITS) - 1);
        let index: HashMap<char, u16> = chars
            .iter()
            .enumerate()
            .map(|(i, c)| (*c, i as u16))
            .collect();
        let mut pairs: Vec<(u64, u8)> = entries
            .iter()
            .filter_map(|(c, v)| Some((pack(&index, c)?, quantize(*v))))
            .collect();
        pairs.sort_unstable_by_key(|p| p.0);
        pairs.dedup_by_key(|p| p.0);
        let mut blocks = Vec::with_capacity(pairs.len() / BLOCK + 1);
        let mut data = Vec::with_capacity(pairs.len() * 4);
        for chunk in pairs.chunks(BLOCK) {
            blocks.push((chunk[0].0, data.len() as u32));
            let mut prev = chunk[0].0;
            for &(key, value) in chunk {
                write_varint(&mut data, key - prev);
                data.push(value);
                prev = key;
            }
        }
        Self {
            index,
            chars,
            count: pairs.len(),
            blocks,
            data,
        }
    }

    pub fn len(&self) -> usize {
        self.count
    }

    pub fn is_empty(&self) -> bool {
        self.count == 0
    }

    /// 某个片段的搭配分。
    pub fn get(&self, chars: &[char]) -> Option<f32> {
        let key = pack(&self.index, chars)?;
        // 最后一个块首键 ≤ key 的块
        let b = self
            .blocks
            .partition_point(|(first, _)| *first <= key)
            .checked_sub(1)?;
        let (first, start) = self.blocks[b];
        let end = self
            .blocks
            .get(b + 1)
            .map_or(self.data.len(), |(_, o)| *o as usize);
        let mut pos = start as usize;
        let mut cur = first;
        while pos < end {
            let (delta, used) = read_varint(&self.data[pos..end])?;
            pos += used;
            cur += delta;
            let value = *self.data.get(pos)?;
            pos += 1;
            if cur == key {
                return Some(dequantize(value));
            }
            if cur > key {
                return None;
            }
        }
        None
    }

    /// 交界处的搭配证据：上文末尾 1～2 个字 + 词开头 1～2 个字（合计不超过 4 个字）的各种拼法里，
    /// 每条命中的片段贡献 `max(0, 分 - base)`，全部加起来（多条证据一起投票，比只取最高分稳：
    /// 越长的片段原始分天然越高，只取最高分会让一条偶然的 4 字片段压过几条一致的短片段）。
    /// 一条都没命中返回 0。
    pub fn junction(&self, context: &str, word: &str, base: f32) -> f32 {
        let tail: Vec<char> = context
            .chars()
            .rev()
            .take(2)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        let head: Vec<char> = word.chars().take(2).collect();
        let mut total = 0.0;
        let mut buf: Vec<char> = Vec::with_capacity(MAX_KEY_CHARS);
        for cl in 1..=tail.len() {
            for wl in 1..=head.len() {
                buf.clear();
                buf.extend_from_slice(&tail[tail.len() - cl..]);
                buf.extend_from_slice(&head[..wl]);
                if let Some(v) = self.get(&buf) {
                    total += (v - base).max(0.0);
                }
            }
        }
        total
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(
            24 + self.chars.len() * 4 + self.blocks.len() * 12 + self.data.len(),
        );
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&(self.chars.len() as u32).to_le_bytes());
        for c in &self.chars {
            out.extend_from_slice(&(*c as u32).to_le_bytes());
        }
        out.extend_from_slice(&(self.count as u32).to_le_bytes());
        out.extend_from_slice(&(self.blocks.len() as u32).to_le_bytes());
        for (first, offset) in &self.blocks {
            out.extend_from_slice(&first.to_le_bytes());
            out.extend_from_slice(&offset.to_le_bytes());
        }
        out.extend_from_slice(&(self.data.len() as u32).to_le_bytes());
        out.extend_from_slice(&self.data);
        out
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, DictError> {
        if bytes.len() < 20 || &bytes[..4] != MAGIC {
            return Err(DictError::BadMagic);
        }
        let mut pos: usize = 4;
        let mut take = |n: usize| -> Result<&[u8], DictError> {
            let end = pos.checked_add(n).ok_or(DictError::Overflow)?;
            let s = bytes.get(pos..end).ok_or(DictError::Truncated)?;
            pos = end;
            Ok(s)
        };
        let u32_of = |s: &[u8]| u32::from_le_bytes(s.try_into().unwrap());
        let n_chars = u32_of(take(4)?) as usize;
        let mut chars = Vec::with_capacity(n_chars);
        for _ in 0..n_chars {
            chars.push(char::from_u32(u32_of(take(4)?)).ok_or(DictError::InvalidUtf8)?);
        }
        let count = u32_of(take(4)?) as usize;
        let n_blocks = u32_of(take(4)?) as usize;
        let block_bytes = take(n_blocks.checked_mul(12).ok_or(DictError::Overflow)?)?;
        let blocks = block_bytes
            .chunks_exact(12)
            .map(|c| {
                (
                    u64::from_le_bytes(c[..8].try_into().unwrap()),
                    u32_of(&c[8..]),
                )
            })
            .collect();
        let data_len = u32_of(take(4)?) as usize;
        let data = take(data_len)?.to_vec();
        let index = chars
            .iter()
            .enumerate()
            .map(|(i, c)| (*c, i as u16))
            .collect();
        Ok(Self {
            index,
            chars,
            count,
            blocks,
            data,
        })
    }
}

fn quantize(v: f32) -> u8 {
    ((v - VALUE_BASE) * 10.0).round().clamp(0.0, 255.0) as u8
}

fn dequantize(q: u8) -> f32 {
    VALUE_BASE + q as f32 / 10.0
}

fn write_varint(out: &mut Vec<u8>, mut v: u64) {
    loop {
        let byte = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}

fn read_varint(bytes: &[u8]) -> Option<(u64, usize)> {
    let mut v = 0u64;
    for (i, b) in bytes.iter().enumerate().take(10) {
        v |= ((b & 0x7f) as u64) << (7 * i);
        if b & 0x80 == 0 {
            return Some((v, i + 1));
        }
    }
    None
}

fn pack(index: &HashMap<char, u16>, chars: &[char]) -> Option<u64> {
    if chars.len() > MAX_KEY_CHARS {
        return None;
    }
    let mut key = 0u64;
    for (i, c) in chars.iter().enumerate() {
        let slot = *index.get(c)? as u64 + 1;
        key |= slot << (SLOT_BITS * (MAX_KEY_CHARS - 1 - i) as u32);
    }
    Some(key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn junction_sums_evidence_and_round_trips() {
        let lm = Collocations::build([
            ("时候到".to_string(), 15.65),
            ("候到".to_string(), 11.0),
            ("回复你".to_string(), 15.85),
        ]);
        let lm = Collocations::from_bytes(&lm.to_bytes()).unwrap();
        assert_eq!(lm.len(), 3);
        let q = |v: f32| dequantize(quantize(v)) - 8.0;
        // 候到 + 时候到 两条证据相加
        assert_eq!(lm.junction("什么时候", "到的", 8.0), q(11.0) + q(15.65));
        assert_eq!(lm.junction("什么时候", "道德", 8.0), 0.0);
        assert_eq!(lm.junction("尽快回复", "你", 8.0), q(15.85));
        assert_eq!(lm.junction("尽快", "回复你", 8.0), 0.0);
        assert_eq!(lm.junction("我会尽快回", "复你", 8.0), q(15.85));
    }

    #[test]
    fn lookups_across_many_blocks() {
        // 一千多条、跨很多块：每一条都能按原值查回来，不存在的查不到
        let base: Vec<char> =
            "的一是了我不人在他有这个上们来到时大地为子中你说生国年着就那和要她出也得里后自以会"
                .chars()
                .collect();
        let mut entries = Vec::new();
        for (i, a) in base.iter().enumerate() {
            for (j, b) in base.iter().enumerate() {
                if (i + j) % 3 != 0 {
                    entries.push((format!("{a}{b}"), 9.0 + ((i * 7 + j) % 100) as f32 / 10.0));
                }
            }
        }
        let lm =
            Collocations::from_bytes(&Collocations::build(entries.clone()).to_bytes()).unwrap();
        assert_eq!(lm.len(), entries.len());
        for (s, v) in &entries {
            let chars: Vec<char> = s.chars().collect();
            assert_eq!(lm.get(&chars), Some(dequantize(quantize(*v))), "{s}");
        }
        assert_eq!(lm.get(&[base[0], base[0]]), None);
    }
}
