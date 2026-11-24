//! 词性标签集：词典（jmdict.tsv）与连接矩阵（matrix.bin）共用同一套 id。
//!
//! 顺序是稳定契约：matrix.bin 按名字写入，加载时逐个校验；改顺序等于换格式。

pub const TAGS: [&str; 18] = [
    "BOS", "EOS", "NOUN", "VERB", "ADJ", "ADV", "ADP", "AUX", "CCONJ", "SCONJ", "PART", "PRON",
    "NUM", "PREF", "DET", "INTJ", "X", "UNK",
];

pub const BOS: u8 = 0;
pub const EOS: u8 = 1;
pub const UNK: u8 = 17;

pub fn id(name: &str) -> Option<u8> {
    TAGS.iter().position(|t| *t == name).map(|i| i as u8)
}

pub fn name(id: u8) -> &'static str {
    TAGS.get(id as usize).copied().unwrap_or("UNK")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_stable() {
        assert_eq!(id("BOS"), Some(0));
        assert_eq!(id("NOUN"), Some(2));
        assert_eq!(id("UNK"), Some(17));
        assert_eq!(id("NOPE"), None);
        assert_eq!(name(3), "VERB");
    }
}
