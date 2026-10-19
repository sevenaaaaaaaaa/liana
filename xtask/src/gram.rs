//! 读取 librime-octagram 的语法模型（`.gram`，如万象 LMDG，CC BY 4.0），抽出字级搭配。
//!
//! 文件格式（见 librime-octagram `gram_db.h` / `gram_encoding.cc`）：
//! - 头部 `grammar::Metadata`：32 字节格式名（`Rime::Grammar/1.0`）、u32 校验和、
//!   u32 双数组单元数、i32 相对偏移（指向双数组）；
//! - darts-clone 双数组：键是 octagram 编码的 2～6 个字（上文末尾若干字 + 下一个词开头若干字），
//!   值是 `ln(频次) × 10000`。
//!
//! 这里自己实现 darts-clone 的单元解码与遍历，不依赖 librime。

/// 双数组单元。
#[derive(Clone, Copy)]
struct Unit(u32);

impl Unit {
    fn has_leaf(self) -> bool {
        (self.0 >> 8) & 1 == 1
    }
    fn value(self) -> u32 {
        self.0 & 0x7fff_ffff
    }
    fn label(self) -> u32 {
        self.0 & (0x8000_0000 | 0xff)
    }
    fn offset(self) -> u32 {
        (self.0 >> 10) << ((self.0 & (1 << 9)) >> 6)
    }
}

pub struct GramFile {
    units: Vec<u32>,
}

impl GramFile {
    pub fn open(path: &str) -> Result<Self, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("读取 {path} 失败: {e}"))?;
        if !bytes.starts_with(b"Rime::Grammar/") || bytes.len() < 48 {
            return Err(format!("{path} 不是 octagram 语法模型"));
        }
        let u32_at = |i: usize| u32::from_le_bytes(bytes[i..i + 4].try_into().unwrap());
        let size = u32_at(36) as usize;
        // OffsetPtr：相对它自己所在位置的偏移
        let start = 40 + i32::from_le_bytes(bytes[40..44].try_into().unwrap()) as usize;
        let end = start + size * 4;
        if end > bytes.len() {
            return Err("双数组越界：文件被截断？".into());
        }
        let units = bytes[start..end]
            .chunks_exact(4)
            .map(|c| u32::from_le_bytes(c.try_into().unwrap()))
            .collect();
        Ok(Self { units })
    }

    pub fn unit_count(&self) -> usize {
        self.units.len()
    }

    /// 精确查询一个编码后的键（自检用）。
    pub fn lookup(&self, key: &[u8]) -> Option<u32> {
        let mut pos = 0usize;
        let mut unit = Unit(self.units[0]);
        for &c in key {
            pos ^= unit.offset() as usize ^ c as usize;
            unit = Unit(*self.units.get(pos)?);
            if unit.label() != c as u32 {
                return None;
            }
        }
        if !unit.has_leaf() {
            return None;
        }
        Some(Unit(self.units[pos ^ unit.offset() as usize]).value())
    }

    /// 遍历全部键值。`keep_prefix` 对已解码的前缀返回 false 时剪掉整棵子树（按字剪枝，省时间）。
    pub fn for_each(
        &self,
        keep_prefix: &dyn Fn(&[char]) -> bool,
        emit: &mut dyn FnMut(&[char], u32),
    ) {
        let mut key: Vec<u8> = Vec::with_capacity(32);
        self.walk(0, &mut key, keep_prefix, emit);
    }

    fn walk(
        &self,
        pos: usize,
        key: &mut Vec<u8>,
        keep_prefix: &dyn Fn(&[char]) -> bool,
        emit: &mut dyn FnMut(&[char], u32),
    ) {
        let unit = Unit(self.units[pos]);
        let base = pos ^ unit.offset() as usize;
        // 只在字的边界上解码并判断（字中间的字节不是完整的字）
        let decoded = decode(key);
        if let Some(chars) = &decoded {
            if !key.is_empty() && !keep_prefix(chars) {
                return;
            }
            if unit.has_leaf() {
                emit(chars, Unit(self.units[base]).value());
            }
        }
        for c in 1..=255usize {
            let child = base ^ c;
            let Some(&u) = self.units.get(child) else {
                continue;
            };
            if Unit(u).label() == c as u32 {
                key.push(c as u8);
                self.walk(child, key, keep_prefix, emit);
                key.pop();
            }
        }
    }
}

/// octagram 编码 → 字；末尾不是完整的字时返回 None。
fn decode(bytes: &[u8]) -> Option<Vec<char>> {
    let mut out = Vec::with_capacity(bytes.len() / 2);
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        let u = if b < 0x80 {
            i += 1;
            b as u32
        } else if b == 0xE0 {
            i += 1;
            0
        } else if b == 0xE1 {
            let x = *bytes.get(i + 1)?;
            i += 2;
            ((x as u32).wrapping_sub(0x40)) << 8
        } else if b & 0xF0 == 0xE0 {
            let n = (b & 0x0F) as usize;
            let tail = bytes.get(i + 1..i + 1 + n)?;
            i += 1 + n;
            tail.iter()
                .fold(0u32, |acc, t| (acc << 7) | (*t as u32 & 0x7F))
        } else {
            let x = *bytes.get(i + 1)?;
            i += 2;
            (((b as u32) - 0x40) << 8) | x as u32
        };
        out.push(char::from_u32(u)?);
    }
    Some(out)
}

/// 字 → octagram 编码（自检用）。
pub fn encode(text: &str) -> Vec<u8> {
    let mut out = Vec::new();
    for ch in text.chars() {
        let u = ch as u32;
        if u < 0x80 {
            out.push(if u == 0 { 0xE0 } else { u as u8 });
        } else if (0x4000..0xA000).contains(&u) {
            if u & 0xFF == 0 {
                out.push(0xE1);
                out.push(((u >> 8) + 0x40) as u8);
            } else {
                out.push(((u >> 8) + 0x40) as u8);
                out.push((u & 0xFF) as u8);
            }
        } else {
            let mut v = u;
            let mut bits = 32;
            while bits > 0 && (v & 0xFE00_0000) == 0 {
                bits -= 7;
                v <<= 7;
            }
            let mut n = (bits + 6) / 7;
            out.push(0xE0 | n as u8);
            while n > 0 {
                n -= 1;
                out.push((((v >> 25) & 0x7F) | 0x80) as u8);
                v <<= 7;
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encoding_round_trips() {
        for s in ["你好", "一丁", "世界很大", "a中b"] {
            assert_eq!(
                decode(&encode(s)).unwrap().into_iter().collect::<String>(),
                s
            );
        }
    }
}
