import Foundation

/// 内置合法拼音音节表（含 lv/lve/nv/nve 的 v 写法）。
///
/// 只用于「任何合法拼音输入至少给出一个候选」的音节 DP 兜底：词库扩容或
/// 会话不可用时，仍能把整串输入切成音节、逐音节取单字。正常输入不查这张表。
enum PinyinSyllables {
    /// 405 个普通话音节（不含声调）。
    private static let table = "a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo da dai dan dang dao de dei deng di dia dian diao die ding diu dong dou du duan dui dun duo e ei en eng er fa fan fang fei fen feng fo fou fu ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun ka kai kan kang kao ke ken keng kong kou ku kua kuai kuan kuang kui kun kuo la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lun luo lv lve ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nu nuan nuo nv nve o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun ran rang rao re ren reng ri rong rou ru ruan rui run ruo sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo"

    static let all: Set<String> = Set(table.split(separator: " ").map(String.init))

    /// 最长音节 6 个字母（zhuang / chuang / shuang）。
    static let maxLength = 6

    /// 把整串拼音切成音节；有任何一段切不动就返回 nil。
    /// extra 用于并入词库派生音节（例如数据里出现的方言/边缘读音）。
    static func split(_ raw: String, extra: Set<String> = []) -> [String]? {
        let characters = Array(raw.lowercased())
        guard !characters.isEmpty, characters.count <= 64 else { return nil }
        let count = characters.count
        var reachable = Array(repeating: false, count: count + 1)
        var pieces = Array(repeating: [String](), count: count + 1)
        reachable[count] = true
        // 从后往前：每一段都取「最长且后缀可切」的音节，O(n × 6)。
        for offset in stride(from: count - 1, through: 0, by: -1) {
            let reach = min(maxLength, count - offset)
            for length in stride(from: reach, through: 1, by: -1) {
                let candidate = String(characters[offset..<(offset + length)])
                guard all.contains(candidate) || extra.contains(candidate) else { continue }
                guard reachable[offset + length] else { continue }
                reachable[offset] = true
                pieces[offset] = [candidate] + pieces[offset + length]
                break
            }
        }
        return reachable[0] ? pieces[0] : nil
    }
}
