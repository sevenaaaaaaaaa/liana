//! 语言包接口契约测试。
//!
//! 这些测试先于实现存在：它们锁定「加一门语言只需要注册一个包」这件事的最小面。
//! 三组断言分别对应三处曾经写死的地方：
//! - 注册表：语言清单来自注册，不来自 `enum Mode`；
//! - 解码：只要求 `decode(input) -> Vec<Candidate>`，不关心实现是查表还是 Viterbi；
//! - 输入闸门：哪些字符能进组合，由包自己决定，不由 `is_ascii_alphabetic()` 统一决定。

use liana_core::language::{FeedPolicy, LanguagePack, Registry};
use liana_core::{Candidate, CandidateKind};

/// 最小语言包：把输入原样大写，用于验证接口本身（不验证任何真实语言）。
struct DummyPack {
    policy: FeedPolicy,
}

impl LanguagePack for DummyPack {
    fn id(&self) -> &'static str {
        "dummy"
    }

    fn label(&self) -> &'static str {
        "Dummy"
    }

    fn feed_policy(&self) -> FeedPolicy {
        self.policy
    }

    fn accepts(&self, ch: char) -> bool {
        match self.policy {
            FeedPolicy::Ascii => ch.is_ascii_alphabetic(),
            FeedPolicy::Unicode => !ch.is_control() && ch != ' ',
        }
    }

    fn decode(&self, input: &str) -> Vec<Candidate> {
        if input.is_empty() {
            return Vec::new();
        }
        vec![Candidate::new(
            input.to_uppercase(),
            input.chars().count(),
            CandidateKind::Word,
            1.0,
        )]
    }
}

fn registry_with(policy: FeedPolicy) -> Registry {
    let mut reg = Registry::new();
    assert!(
        reg.register(Box::new(DummyPack { policy })),
        "首次注册应成功"
    );
    reg
}

#[test]
fn registry_lists_registered_packs_and_rejects_duplicates() {
    let mut reg = Registry::new();
    assert_eq!(reg.len(), 0, "空注册表不该有语言");
    assert!(reg.ids().is_empty(), "空注册表 ids 应为空");

    assert!(reg.register(Box::new(DummyPack {
        policy: FeedPolicy::Ascii
    })));
    assert_eq!(reg.len(), 1);
    assert_eq!(reg.ids(), vec!["dummy"], "清单只含已注册的 id");

    // 同一 id 再注册一次：拒绝，先注册者保留（不静默覆盖）。
    assert!(
        !reg.register(Box::new(DummyPack {
            policy: FeedPolicy::Unicode
        })),
        "重复 id 必须被拒绝"
    );
    assert_eq!(reg.len(), 1, "被拒绝的注册不能改变表");
    assert_eq!(
        reg.get("dummy").map(|p| p.feed_policy()),
        Some(FeedPolicy::Ascii),
        "先注册的包不能被后注册的覆盖"
    );
    assert!(reg.get("nope").is_none(), "未知 id 应返回 None");
}

#[test]
fn pack_decodes_into_candidates_and_is_pure() {
    let reg = registry_with(FeedPolicy::Ascii);
    let pack = reg.get("dummy").expect("已注册");

    let cands = pack.decode("abc");
    assert_eq!(cands.len(), 1);
    assert_eq!(cands[0].text, "ABC");
    assert_eq!(cands[0].consumed, 3, "consumed 是字符数，不是字节数");
    assert_eq!(cands[0].kind, CandidateKind::Word);

    assert!(pack.decode("").is_empty(), "空输入不出候选");

    // 纯函数契约：同输入必须同输出（排序与打分都不许带内部可变状态）。
    let again = pack.decode("abc");
    assert_eq!(again[0].text, cands[0].text);
    assert_eq!(again[0].consumed, cands[0].consumed);
}

#[test]
fn feed_policy_decides_which_chars_enter_the_composition() {
    let ascii = registry_with(FeedPolicy::Ascii);
    let ascii = ascii.get("dummy").expect("已注册");
    assert_eq!(ascii.feed_policy(), FeedPolicy::Ascii);
    assert!(ascii.accepts('a'));
    assert!(!ascii.accepts('é'), "ASCII 语言包不接受变音符");
    assert!(!ascii.accepts('日'), "ASCII 语言包不接受 CJK");
    assert!(!ascii.accepts('1'), "数字不是字母，默认不进组合");

    // 同一个 trait 下，另一个包可以放开 Unicode：韩文直打、变音符直打的前提。
    let mut reg = Registry::new();
    reg.register(Box::new(DummyPack {
        policy: FeedPolicy::Unicode,
    }));
    let uni = reg.get("dummy").expect("已注册");
    assert_eq!(uni.feed_policy(), FeedPolicy::Unicode);
    assert!(uni.accepts('é'));
    assert!(uni.accepts('한'));
    assert!(!uni.accepts(' '), "空格永远由前端处理");
}
