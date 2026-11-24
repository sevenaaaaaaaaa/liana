//! 词性连接矩阵：matrix.bin 的加载与查询。
//!
//! 格式（小端）：magic JAM1 · u8 version · u8 ntags · ntags×(u8 len + name) · ntags²×i16
//! cost = -ln(p(next | prev)) × 100。数值越小越常见。
//!
//! 内嵌数据损坏时不 panic：退回全零矩阵（等价于「连接不惩罚」），由测试守住
//! 内嵌文件本身可解析。输入法崩溃比排序差更不可接受。

use std::sync::OnceLock;

use crate::pos;

pub struct Matrix {
    n: usize,
    costs: Vec<i16>,
}

impl Matrix {
    pub fn parse(bytes: &[u8]) -> Result<Self, &'static str> {
        if bytes.len() < 6 || &bytes[0..4] != b"JAM1" {
            return Err("magic 不是 JAM1");
        }
        if bytes[4] != 1 {
            return Err("不支持的矩阵版本");
        }
        let n = bytes[5] as usize;
        let mut i = 6;
        let mut names = Vec::with_capacity(n);
        for _ in 0..n {
            let len = *bytes.get(i).ok_or("标签名截断")? as usize;
            i += 1;
            let raw = bytes.get(i..i + len).ok_or("标签名截断")?;
            names.push(std::str::from_utf8(raw).map_err(|_| "标签名不是 UTF-8")?);
            i += len;
        }
        if names.as_slice() != pos::TAGS {
            return Err("标签集与内核不一致");
        }
        let need = n * n * 2;
        let raw = bytes.get(i..i + need).ok_or("矩阵数据截断")?;
        let costs = raw
            .chunks_exact(2)
            .map(|c| i16::from_le_bytes([c[0], c[1]]))
            .collect();
        Ok(Self { n, costs })
    }

    pub fn embedded() -> &'static Matrix {
        static M: OnceLock<Matrix> = OnceLock::new();
        M.get_or_init(|| {
            Matrix::parse(include_bytes!("../data/matrix.bin")).unwrap_or_else(|e| {
                debug_assert!(false, "内嵌 matrix.bin 损坏：{e}");
                Matrix { n: pos::TAGS.len(), costs: vec![0; pos::TAGS.len() * pos::TAGS.len()] }
            })
        })
    }

    pub fn cost(&self, from: u8, to: u8) -> i32 {
        let idx = from as usize * self.n + to as usize;
        self.costs.get(idx).copied().unwrap_or(0) as i32
    }

    pub fn size(&self) -> usize {
        self.n
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_matrix_is_well_formed() {
        let m = Matrix::embedded();
        assert_eq!(m.size(), pos::TAGS.len());
        let noun_adp = m.cost(pos::id("NOUN").unwrap(), pos::id("ADP").unwrap());
        let noun_int = m.cost(pos::id("NOUN").unwrap(), pos::id("INTJ").unwrap());
        assert!(noun_adp < noun_int, "NOUN→ADP {noun_adp} 应低于 NOUN→INTJ {noun_int}");
    }

    #[test]
    fn bad_magic_is_rejected() {
        assert!(Matrix::parse(b"XXXX").is_err());
    }
}
