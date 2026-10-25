//! 拆字数据：部件别名表 + 常用字拆分表。由 /tmp/gen_radix.py 生成（全部条目经校验）。

/// 部件读音键 → 别名（拼音全拼小写；查询与拆分都按此归一）。
pub const COMPONENTS: &[(&str, &str)] = &[
    ("ri", "日 日字旁"),
    ("yue", "月 月字旁"),
    ("shui", "水 氵 三点水"),
    ("huo", "火 灬 四点底 火字旁"),
    ("mu", "木 目 木字旁 目字旁"),
    ("jin", "金 钅 金字旁"),
    ("tu", "土 土字旁"),
    ("kou", "口 口字旁"),
    ("ren", "人 亻 单人旁"),
    ("nv", "女 女字旁"),
    ("zi", "子 子字旁"),
    ("shan", "山 山字旁"),
    ("shi", "石 十 石字旁 十字旁"),
    ("tian", "田 田字旁"),
    ("he", "禾 禾木旁"),
    ("chong", "虫 虫字旁"),
    ("yu", "鱼 雨 鱼字旁 雨字头"),
    ("niao", "鸟 鸟字旁"),
    ("ma", "马 马字旁"),
    ("quan", "犬 犭 反犬旁 狗"),
    ("cao", "艹 草字头 草"),
    ("zhu", "竹 主 竹字头 主字头"),
    ("shou", "手 扌 提手旁"),
    ("xin", "心 忄 竖心旁 心字底"),
    ("yan", "言 讠 言字旁"),
    ("si", "纟 纟旁 绞丝旁"),
    ("che", "车 车字旁"),
    ("er", "儿 二 儿字底 两横"),
    ("da", "大 大字头"),
    ("xiao", "小 小字头"),
    ("gong", "工 弓 工字旁 弓字旁"),
    ("li", "立 里 立字头"),
    ("fang", "方 方字旁"),
    ("bai", "白 白字旁"),
    ("dao", "刀 刂 立刀旁"),
    ("men", "门 门字框"),
    ("wang", "王 王字旁"),
    ("jian", "见 见字旁 见字底"),
    ("bei", "贝 贝字旁 贝字底"),
    ("zu", "足 ⻊ 足字旁"),
    ("mi", "米 米字旁"),
    ("cun", "寸 寸字旁"),
    ("yi", "衣 衤 衣字旁"),
    ("xi", "西 夕 西字头 夕字旁"),
    ("zhi", "止 止字旁"),
    ("you", "又 又字旁"),
    ("ye", "也 也字旁"),
    ("ji", "己 已 巳"),
    ("ba", "八 八字头"),
    ("gu", "古 古字旁"),
    ("yuan", "元 元字旁"),
    ("qian", "千 千字头"),
    ("bao", "宀 宝盖头 宝盖"),
    ("xue", "穴 穴字头"),
    ("guang", "广 广字头"),
    ("chang", "厂 厂字头 长 长字旁"),
    ("fu", "父 父字头 斧"),
    ("pian", "片 片字旁"),
    ("ya", "牙 牙字旁"),
    ("bi", "比 比字旁"),
    ("feng", "风 风字旁"),
    ("mao", "矛 矛字旁"),
    ("dou", "斗"),
    ("wan", "万"),
    ("bing", "冫 两点水"),
    ("zou", "走 辶 走之 走之底 走字旁"),
    ("hua", "化"),
    ("dui", "对 对字旁"),
    ("yun", "云"),
    ("jing", "井"),
    ("gui", "圭 圭字旁"),
    ("ge", "各 各字旁 夂 折文"),
    ("mei", "每 每字旁"),
    ("xiang", "相 相字旁"),
    ("yang", "羊 羊字旁 央"),
    ("xiang3", "象 象字底"),
    ("gao", "高 高字头"),
    ("zeng", "曾 曾字头"),
    ("pi", "皮 皮字旁"),
    ("bao1", "包 包字头 勹"),
    ("feng1", "丰 丰字旁"),
    ("shen", "身 身字旁"),
    ("gu2", "骨 骨字旁"),
    ("lu", "鹿 鹿字头"),
    ("ma3", "麻 麻字头"),
    ("gui3", "鬼 鬼字旁"),
    ("hei", "黑 黑字旁"),
    ("qi2", "其 其字底"),
    ("shen2", "甚"),
    ("long", "龙 龙"),
    ("deng", "登 癶 登字头"),
];

/// 常用字拆分：`字\t已排序读音键\t拆法说明`。
pub const CHARS: &str = r#"
明	ri yue	日月 → 明
鲜	yang yu	鱼羊 → 鲜
岩	shan shi	山石 → 岩
尘	tu xiao	小土 → 尘
尖	da xiao	小大 → 尖
苗	cao tian	艹田 → 苗
雷	tian yu	雨田 → 雷
雪	shou yu	雨彐 → 雪
村	cun mu	木寸 → 村
树	dui mu	木对 → 树
林	mu mu	木木 → 林
森	mu mu mu	木木木 → 森
李	mu zi	木子 → 李
杨	mu yang	木𠃓 → 杨
松	gong mu	木公 → 松
柏	bai mu	木白 → 柏
梢	mu xiao	木肖 → 梢
江	gong shui	氵工 → 江
湖	gu shui yue	氵古月 → 湖
海	mei shui	氵每 → 海
港	shui xiang	氵巷 → 港
沙	shui xiao	氵少 → 沙
爆	bao huo	火暴 → 爆
场	chang tu	土𠃓 → 场
地	tu ye	土也 → 地
坡	pi tu	土皮 → 坡
塔	da tu	土荅 → 塔
妈	ma nv	女马 → 妈
好	nv zi	女子 → 好
孙	xiao zi	子小 → 孙
张	chang gong	弓长 → 张
钱	jin qian	钅戋 → 钱
铁	jin shi	钅失 → 铁
针	jin shi	钅十 → 针
错	jin xi	钅昔 → 错
喝	he kou	口曷 → 喝
听	jin kou	口斤 → 听
唱	chang kou	口昌 → 唱
呀	kou ya	口牙 → 呀
他	ren ye	亻也 → 他
们	men ren	亻门 → 们
你	er ren	亻尔 → 你
休	mu ren	亻木 → 休
估	gu ren	亻古 → 估
位	li ren	亻立 → 位
住	ren zhu	亻主 → 住
偏	pian ren	亻扁 → 偏
把	ba shou	扌巴 → 把
抱	bao shou	扌包 → 抱
拉	li shou	扌立 → 拉
摆	ba shou	扌罢 → 摆
找	ge shou	扌戈 → 找
想	xiang xin	相心 → 想
忘	wang xin	亡心 → 忘
念	jin xin	今心 → 念
怒	nv xin	奴心 → 怒
惊	jing xin	忄京 → 惊
怕	bai xin	忄白 → 怕
说	dui yan	讠兑 → 说
认	ren yan	讠人 → 认
识	yan zhi	讠只 → 识
谈	yan yan	讠炎 → 谈
红	gong si	纟工 → 红
绿	lu si	纟录 → 绿
线	jian si	纟戋 → 线
纸	shi si	纟氏 → 纸
级	ji si	纟及 → 级
纪	ji si	纟己 → 纪
理	li wang	王里 → 理
现	jian wang	王见 → 现
珠	wang zhu	王朱 → 珠
看	mu shou	手目 → 看
冒	mu yue	曰目 → 冒
鸡	niao you	又鸟 → 鸡
鸣	kou niao	口鸟 → 鸣
鸦	niao ya	牙鸟 → 鸦
独	chong quan	犭蜀 → 独
狮	quan shi	犭师 → 狮
花	cao hua	艹化 → 花
茶	cao mu ren	艹人木 → 茶
蓝	cao jian	艹监 → 蓝
笔	mao zhu	竹毛 → 笔
答	da zhu	竹合 → 答
简	jian zhu	竹间 → 简
算	mu zhu	竹目 → 算
箭	qian zhu	竹前 → 箭
晒	ri xi	日西 → 晒
晶	ri ri ri	日日日 → 晶
起	ji zou	走己 → 起
越	yue zou	走戉 → 越
进	jing zou	井辶 → 进
远	yuan zou	元辶 → 远
运	yun zou	云辶 → 运
过	cun zou	寸辶 → 过
道	shou zou	首辶 → 道
边	li zou	力辶 → 边
达	da zou	大辶 → 达
岚	feng shan	山风 → 岚
岛	niao shan	山鸟 → 岛
峰	feng shan	山夆 → 峰
坤	shen tu	土申 → 坤
碎	shi zu	石卒 → 碎
碰	bing shi	石并 → 碰
砚	jian shi	石见 → 砚
思	tian xin	田心 → 思
男	li tian	田力 → 男
备	fu tian	夂田 → 备
秋	he huo	禾火 → 秋
科	dou he	禾斗 → 科
称	er he	禾尔 → 称
秘	bi he	禾必 → 秘
香	he ri	禾日 → 香
秃	he ji	禾几 → 秃
和	he kou	禾口 → 和
蚁	chong yi	虫义 → 蚁
蚂	chong ma	虫马 → 蚂
蜂	chong feng	虫夆 → 蜂
货	bei hua	化贝 → 货
贤	bei you	又贝 → 贤
跑	bao zu	⻊包 → 跑
路	ge zu	⻊各 → 路
踏	da zu	⻊沓 → 踏
粒	li mi	米立 → 粒
类	da mi	米大 → 类
付	cun ren	亻寸 → 付
衬	cun yi	衤寸 → 衬
初	dao yi	衤刀 → 初
被	pi yi	衤皮 → 被
褐	he yi	衤曷 → 褐
要	nv xi	西女 → 要
票	shi xi	西示 → 票
多	xi xi	夕夕 → 多
名	kou xi	夕口 → 名
岁	shan xi	山夕 → 岁
罗	si xi	罒夕 → 罗
灶	huo tu	火土 → 灶
灭	huo yi	火一 → 灭
灰	huo huo	𠂇火 → 灰
炎	huo huo	火火 → 炎
鑫	jin jin jin	金金金 → 鑫
淼	shui shui shui	水水水 → 淼
焱	huo huo huo	火火火 → 焱
磊	shi shi shi	石石石 → 磊
众	ren ren ren	人人人 → 众
品	kou kou kou	口口口 → 品
昌	ri ri	日日 → 昌
朋	yue yue	月月 → 朋
双	you you	又又 → 双
从	ren ren	人人 → 从
羽	xi xi	习习 → 羽
串	kou kou	口口 → 串
出	shan shan	山山 → 出
款	qian shi	士示欠 → 款
歌	ge qian	哥欠 → 歌
欢	qian you	又欠 → 欢
吹	kou qian	口欠 → 吹
饮	qian shi	饣欠 → 饮
次	bing qian	冫欠 → 次
欲	gu qian	谷欠 → 欲
芳	cao fang	艹方 → 芳
英	cao yang	艹央 → 英
若	cao you	艹右 → 若
苦	cao gu	艹古 → 苦
荷	cao he	艹何 → 荷
莉	cao li	艹利 → 莉
莫	cao da ri	艹日大 → 莫
"#;
