//! 语言包：让「加一门语言」变成注册一个包，而不是改一处枚举。
//!
//! 契约只有四条：id 稳定、解码是纯函数、输入闸门由包自己说、注册表不静默覆盖。
//! 引擎按 id 取包并调用 `decode`；前端按 `feed_policy` 决定哪些键先交给包。
//!
//! 这一层不关心实现深浅：拼音的 DP、日文的 Viterbi、韩文的音节组合都在各自的
//! 包里，注册表只认 trait。

use std::collections::BTreeMap;

use crate::types::Candidate;

/// 包接受哪些字符进入组合态。
///
/// 这是过去写死在 `engine::feed` 里的 `is_ascii_alphabetic()` 的具体化：
/// 罗马字方案（拼音/日文/西欧）只吃 ASCII；直打方案（韩文 2-beolsik、变音符）
/// 必须吃 Unicode。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FeedPolicy {
    /// 只有 ASCII 字母进组合（其余字符由前端原样上屏）。
    Ascii,
    /// 非控制字符都可进组合（空格与换行始终由前端处理）。
    Unicode,
}

impl FeedPolicy {
    pub fn id(self) -> &'static str {
        match self {
            FeedPolicy::Ascii => "ascii",
            FeedPolicy::Unicode => "unicode",
        }
    }

    /// 默认闸门：包可以覆盖，但必须能从这里看出它为什么收/不收某个字符。
    pub fn accepts(self, ch: char) -> bool {
        match self {
            FeedPolicy::Ascii => ch.is_ascii_alphabetic(),
            FeedPolicy::Unicode => !ch.is_control() && ch != ' ',
        }
    }
}

/// 一门语言的解码能力。
///
/// 包是有状态的也没关系（词频缓存、词典句柄），但 `decode` 必须是纯函数：
/// 同输入必得同输出，排序不许依赖内部可变状态。
///
/// 不继承 `Decoder`：引擎只需要 `LanguagePack` 一个入口，避免每种语言写两遍同名方法。
pub trait LanguagePack: Send + Sync {
    /// 稳定 id：出现在 FFI、菜单、偏好里，一经发布不再改。
    fn id(&self) -> &'static str;

    /// 菜单显示名（用户语言原文，如「日本語」）。
    fn label(&self) -> &'static str;

    /// 该包对输入的接受范围。
    fn feed_policy(&self) -> FeedPolicy;

    /// 这个字符能否进入组合。默认按策略判断；需要特例（例如日文的 `'`）就覆盖。
    fn accepts(&self, ch: char) -> bool {
        self.feed_policy().accepts(ch)
    }

    /// 把组合串解成候选。纯函数：同输入必得同输出。
    fn decode(&self, input: &str) -> Vec<Candidate>;

    /// 预编辑串（用户还没上屏时看到的那行）。默认与输入相同；
    /// 需要转写的语言覆盖它（日语罗马字要显示成假名）。
    fn preedit(&self, input: &str) -> String {
        input.to_string()
    }
}

/// 已注册语言包。按 id 字典序枚举，保证菜单顺序跨平台一致。
#[derive(Default)]
pub struct Registry {
    packs: BTreeMap<&'static str, Box<dyn LanguagePack>>,
}

impl Registry {
    pub fn new() -> Self {
        Self::default()
    }

    /// 注册一个包。id 重复时拒绝并返回 `false`：不静默覆盖已注册的能力。
    pub fn register(&mut self, pack: Box<dyn LanguagePack>) -> bool {
        let id = pack.id();
        if id.is_empty() || self.packs.contains_key(id) {
            return false;
        }
        self.packs.insert(id, pack);
        true
    }

    pub fn get(&self, id: &str) -> Option<&dyn LanguagePack> {
        self.packs.get(id).map(|p| p.as_ref())
    }

    /// 已注册语言的 id（字典序）。
    pub fn ids(&self) -> Vec<&'static str> {
        self.packs.keys().copied().collect()
    }

    pub fn len(&self) -> usize {
        self.packs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.packs.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Empty;

    impl LanguagePack for Empty {
        fn id(&self) -> &'static str {
            "empty"
        }
        fn label(&self) -> &'static str {
            "Empty"
        }
        fn feed_policy(&self) -> FeedPolicy {
            FeedPolicy::Ascii
        }
        fn decode(&self, _input: &str) -> Vec<Candidate> {
            Vec::new()
        }
    }

    #[test]
    fn default_gate_follows_policy() {
        assert!(FeedPolicy::Ascii.accepts('a'));
        assert!(!FeedPolicy::Ascii.accepts('é'));
        assert!(FeedPolicy::Unicode.accepts('한'));
        assert!(!FeedPolicy::Unicode.accepts(' '));
        assert!(!FeedPolicy::Unicode.accepts('\n'));
    }

    #[test]
    fn empty_id_is_rejected() {
        struct Bad;
        impl LanguagePack for Bad {
            fn id(&self) -> &'static str {
                ""
            }
            fn label(&self) -> &'static str {
                "Bad"
            }
            fn feed_policy(&self) -> FeedPolicy {
                FeedPolicy::Ascii
            }
            fn decode(&self, _input: &str) -> Vec<Candidate> {
                Vec::new()
            }
        }
        let mut reg = Registry::new();
        assert!(!reg.register(Box::new(Bad)), "空 id 不该进注册表");
        assert!(reg.is_empty());
        assert!(reg.register(Box::new(Empty)));
        assert_eq!(reg.ids(), vec!["empty"]);
    }

    #[test]
    fn default_accepts_uses_policy() {
        let reg = {
            let mut r = Registry::new();
            r.register(Box::new(Empty));
            r
        };
        let p = reg.get("empty").unwrap();
        assert!(p.accepts('z'), "默认实现走 feed_policy");
        assert!(!p.accepts('汉'));
    }
}
