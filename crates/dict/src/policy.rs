//! 增强词库的自动装载策略：**不让用户选，只由程序决定要不要加载**。
//!
//! 动机：把「在线词库」做成一张带下载按钮的列表，等于把选择成本推给用户——
//! 用户不知道「西药」「成语」该不该装，装多了怕占内存，装少了又觉得打不出词。
//! 松萝的做法是：随包把各个维度的词包都带上（构建期合并进 base.ifd），
//! 运行期只做**加权与按需装载**，界面上不出现任何「下载/卸载词库」的入口。
//!
//! 三个输入决定装载：
//! 1. 内存预算（移动端键盘扩展只有几十 MB，桌面可以全量）；
//! 2. 当前上下文（前台 App 的 bundle id、最近的输入文本）；
//! 3. 维度本身的常驻价值（核心词、中英混合词必须常驻）。
//!
//! 输出是「该加载哪些维度 + 各自权重」，由引擎写进词库的 freq 缩放，
//! 因此同一份数据在不同场景下排序不同，但没有任何一条被用户手动关掉。

/// 词库维度。每一项对应 `crates/dict/data/packs` 下的一批词包文件。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Domain {
    /// 核心常用词（base-large 的主体），永远加载。
    Core,
    /// 中英混合（Wi-Fi / App / PPT）。
    Mixed,
    Idioms,
    Slang,
    Food,
    Places,
    Finance,
    Medical,
    People,
    Apps,
    Office,
    It,
    Ai,
    Car,
    Companies,
    Poem,
    Life,
}

impl Domain {
    pub const ALL: [Domain; 17] = [
        Domain::Core, Domain::Mixed, Domain::Idioms, Domain::Slang, Domain::Food, Domain::Places,
        Domain::Finance, Domain::Medical, Domain::People, Domain::Apps, Domain::Office, Domain::It,
        Domain::Ai, Domain::Car, Domain::Companies, Domain::Poem, Domain::Life,
    ];

    /// 该维度对应的词包文件（相对 `crates/dict/data/packs`）。
    pub fn packs(self) -> &'static [&'static str] {
        match self {
            Domain::Core => &[],
            Domain::Mixed => &["default/english-mixed.tsv"],
            Domain::Idioms => &["default/idioms.tsv"],
            Domain::Slang => &["default/slang.tsv", "default/hot.tsv", "default/annual.tsv"],
            Domain::Food => &["default/food.tsv"],
            Domain::Places => &["default/places.tsv", "default/places-extra.tsv"],
            Domain::Finance => &["default/finance.tsv", "default/finance-extra.tsv"],
            Domain::Medical => &["default/medical-extra.tsv", "optional/medical.tsv"],
            Domain::People => &["default/names.tsv", "optional/people.tsv"],
            Domain::Apps => &["default/apps.tsv"],
            Domain::Office => &["default/office.tsv"],
            Domain::It => &["default/it.tsv"],
            Domain::Ai => &["default/ai.tsv"],
            Domain::Car => &["default/car.tsv"],
            Domain::Companies => &["default/companies.tsv"],
            Domain::Poem => &["default/poem-extra.tsv", "optional/poem.tsv"],
            Domain::Life => &["default/life.tsv", "optional/animal.tsv", "optional/law.tsv"],
        }
    }

    /// 常驻价值：核心与中英混合是「任何场景都要有」的，其余是可加权的。
    pub fn resident(self) -> bool {
        matches!(self, Domain::Core | Domain::Mixed)
    }
}

/// 内存预算档位。移动端键盘扩展给 Constrained，桌面给 Generous。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Budget {
    /// 只能带核心 + 中英混合 + 当前上下文那一个维度。
    Constrained,
    /// 默认：核心 + 常用维度，长尾维度按上下文补。
    Standard,
    /// 桌面：全部维度都在。
    Generous,
}

/// 自动装载决策结果：维度 → 权重（1.0 = 常规，>1 表示当前上下文更相关）。
#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    pub domains: Vec<(Domain, f32)>,
}

impl Plan {
    pub fn contains(&self, domain: Domain) -> bool {
        self.domains.iter().any(|(d, _)| *d == domain)
    }
    pub fn weight(&self, domain: Domain) -> f32 {
        self.domains.iter().find(|(d, _)| *d == domain).map(|(_, w)| *w).unwrap_or(0.0)
    }
}

/// 上下文推断：从 bundle id 或最近文本里认场景，用户不需要开口。
/// 命中即给对应维度加权，未命中就按预算档位默认装载。
pub fn infer(text: &str) -> Vec<Domain> {
    let lowered = text.to_ascii_lowercase();
    let mut domains = Vec::new();
    let mut hit = |needles: &[&str], domain: Domain| {
        if needles.iter().any(|n| lowered.contains(n)) {
            domains.push(domain);
        }
    };
    hit(&["hospital", "medical", "doctor", "clinic", "健康", "医"], Domain::Medical);
    hit(&["stock", "fund", "trade", "finance", "bank", "excel", "账", "股"], Domain::Finance);
    hit(&["map", "travel", "trip", "hotel", "flight", "导航", "旅"], Domain::Places);
    hit(&["wechat", "qq", "telegram", "discord", "slack", "聊天", "消息"], Domain::Slang);
    hit(&["word", "page", "docs", "notion", "office", "文档", "写作"], Domain::Office);
    hit(&["github", "code", "terminal", "iterm", "xcode", "vim"], Domain::It);
    hit(&["chatgpt", "claude", "openai", "deepseek", "ai"], Domain::Ai);
    hit(&["appstore", "app", "google", "browser", "safari", "chrome"], Domain::Apps);
    hit(&["uber", "didi", "map", "car", "司机", "打车"], Domain::Car);
    hit(&["food", "meituan", "ele", "restaurant", "外卖", "吃"], Domain::Food);
    hit(&["mail", "mail", "邮箱", "邮件"], Domain::Office);
    hit(&["law", "法规", "合同", "律师"], Domain::Life);
    domains.sort_unstable();
    domains.dedup();
    domains
}

/// 决策入口：给定预算与上下文，返回要装载的维度及权重。
/// 结果里永远包含 Core 与 Mixed——这两个维度不允许被关掉。
pub fn plan(budget: Budget, context: Option<&str>) -> Plan {
    let relevant = context.map(infer).unwrap_or_default();
    let mut domains: Vec<(Domain, f32)> = Vec::new();
    fn push(domains: &mut Vec<(Domain, f32)>, domain: Domain, weight: f32) {
        if let Some(slot) = domains.iter_mut().find(|(d, _)| *d == domain) {
            slot.1 = slot.1.max(weight);
        } else {
            domains.push((domain, weight));
        }
    }

    push(&mut domains, Domain::Core, 1.0);
    push(&mut domains, Domain::Mixed, 1.0);

    let default_breadth: &[Domain] = match budget {
        Budget::Constrained => &[],
        Budget::Standard => &[
            Domain::Idioms,
            Domain::Office,
            Domain::It,
            Domain::Apps,
            Domain::Places,
            Domain::Food,
            Domain::Slang,
            Domain::People,
            Domain::Life,
        ],
        Budget::Generous => &Domain::ALL,
    };
    for domain in default_breadth {
        if !domain.resident() {
            push(&mut domains, *domain, 1.0);
        }
    }
    // 上下文命中的维度：一律加权，且不受预算限制（Constrained 也允许带一个）。
    for domain in relevant {
        push(&mut domains, domain, 1.6);
    }
    domains.sort_by_key(|(d, _)| *d);
    Plan { domains }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn core_and_mixed_are_never_optional() {
        for budget in [Budget::Constrained, Budget::Standard, Budget::Generous] {
            let plan = plan(budget, None);
            assert!(plan.contains(Domain::Core));
            assert!(plan.contains(Domain::Mixed));
        }
    }

    #[test]
    fn constrained_budget_keeps_only_resident_plus_context() {
        let plan = plan(Budget::Constrained, Some("com.tencent.xinWeChat"));
        assert!(plan.contains(Domain::Slang));
        assert!(plan.weight(Domain::Slang) > 1.0);
        assert!(!plan.contains(Domain::Poem));
        assert!(!plan.contains(Domain::Car));
    }

    #[test]
    fn generous_budget_loads_every_dimension() {
        let plan = plan(Budget::Generous, None);
        for domain in Domain::ALL {
            assert!(plan.contains(domain), "缺少维度 {:?}", domain);
        }
    }

    #[test]
    fn context_promotes_its_dimension() {
        let plan = plan(Budget::Standard, Some("com.microsoft.Excel"));
        assert!(plan.weight(Domain::Finance) > plan.weight(Domain::Food));
    }

    #[test]
    fn infer_handles_several_scenes_and_is_stable() {
        assert!(infer("com.apple.mobilemail").contains(&Domain::Office));
        assert!(infer("聊天 记录").contains(&Domain::Slang));
        assert_eq!(infer(""), Vec::new());
        let mut first = infer("github copilot");
        let mut second = infer("github copilot");
        first.sort_unstable();
        second.sort_unstable();
        assert_eq!(first, second);
    }
}
