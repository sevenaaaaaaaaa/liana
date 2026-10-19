/* Liana C ABI v1
 *
 * 约定：
 * - 所有返回的 char* 由调用方用 liana_free_string 释放；
 * - 所有函数在内部捕获 panic，不会跨 FFI 边界展开；
 * - 组合态以 JSON 返回，字段见 liana_composition_json 注释。
 */
#ifndef LIANA_H
#define LIANA_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LianaSession LianaSession;
typedef struct LianaAppMode LianaAppMode;
typedef struct LianaEvolution LianaEvolution;

/* 创建会话。mode: "pinyin" | "flypy" | "mspy" | "zrm" | "en" | "ja"；
 * 传 NULL 时使用内置词典与拼音模式。 */
LianaSession *liana_new(const char *mode);

/* 使用外部 IFD1 词典文件创建会话；失败时回退内置词典。 */
LianaSession *liana_new_with_dict(const char *mode, const char *dict_path);

/* 基础词库 + 词包目录（目录里的 *.tsv / *.txt：一行一个词，可选「词\t拼音\t词频」，
 * 没写拼音的自动注音）。进程内共享同一份词库；任一参数为 NULL 时跳过该层。 */
LianaSession *liana_new_with_layers(const char *mode, const char *dict_path, const char *layers_dir);

void liana_free(LianaSession *session);

/* 输入一个字符（UTF-8，单个码点）。返回 1 表示被接受。 */
int32_t liana_feed(LianaSession *session, const char *utf8_char);

int32_t liana_backspace(LianaSession *session);

void liana_clear(LianaSession *session);

/* 切换模式，返回 1 表示成功。 */
int32_t liana_set_mode(LianaSession *session, const char *mode);

/* 当前模式 id。 */
char *liana_mode(LianaSession *session);

/* 简繁显示：on 非 0 时候选转成繁体（学习与重排仍以简体为准）。 */
int32_t liana_set_traditional(LianaSession *session, int32_t on);
int32_t liana_traditional(LianaSession *session);

/* 组合态 JSON：
 * {"raw":"nihao","preedit":"ni hao","candidates":[
 *    {"text":"你好","consumed":5,"kind":"sentence","comment":"ni hao","reading":"exact"}]}
 * "reading" 仅在 comment 是拼音读音时出现："exact" = 与输入拼写一致（可隐藏），
 * "corrected" = 模糊音 / 纠错 / 简拼 / 补全得到的读音（建议显示）。
 * 无 "reading" 的 comment 是标签（短语、表情名等），应始终显示。
 */
char *liana_composition_json(LianaSession *session);

/* 选择候选上屏，返回提交文本；索引越界返回 NULL。 */
char *liana_select(LianaSession *session, uint32_t index);

/* 原样上屏当前缓冲，返回提交文本；缓冲为空返回 NULL。 */
char *liana_commit_raw(LianaSession *session);

/* 用户词学习：导入/导出 TSV（词\t次数），供加密存储层使用。 */
char *liana_user_export(LianaSession *session);

int32_t liana_user_import(LianaSession *session, const char *tsv);

/* 外部文本上屏（语音等）的学习入口：记词并更新二元组上下文；成功 0，参数无效 -1。 */
int32_t liana_record_commit(LianaSession *session, const char *text);

/* 备份与恢复：导出带版本头与 CRC32 的明文包（前端负责加密落盘、明文导出二次确认）；
 * 导入时 merge 非 0 表示同名条目取较大次数，返回条目数，失败返回 -1。 */
char *liana_backup_export(LianaSession *session);
int32_t liana_backup_import(LianaSession *session, const char *text, int32_t merge);

void liana_free_string(char *s);

/* 本地 AI 增强（零云 API）：模型目录与内存推荐，JSON 由调用方释放。 */
char *liana_ai_catalog_json(void);
char *liana_ai_recommend_json(uint64_t total_ram_mb);

/* 每应用中英模式记忆：本地统计模型，只存 bundle id 与票数，无按键内容。
 * 句柄独立于输入会话，整个进程共享一份；持久化由前端负责。 */
LianaAppMode *liana_app_mode_new(void);
void liana_app_mode_free(LianaAppMode *memory);

/* 记录一次信号：zh 非 0 为中文侧；strong 非 0 为手动切换（Shift/菜单），
 * 否则为上屏弱信号；now 为 Unix 秒。返回 1 表示已记录。 */
int32_t liana_app_mode_observe(LianaAppMode *memory, const char *app_id,
                                   int32_t zh, int32_t strong, uint64_t now);

/* 该应用该用中文还是英文？1 = 中文，0 = 英文，-1 = 样本不足不干预。 */
int32_t liana_app_mode_decide(LianaAppMode *memory, const char *app_id,
                                  uint64_t now);

/* 忘记单个应用的偏好。返回 1 表示存在过并已删除。 */
int32_t liana_app_mode_forget(LianaAppMode *memory, const char *app_id);

/* 清空全部学习结果（关闭学习开关时调用，不留数据）。 */
void liana_app_mode_forget_all(LianaAppMode *memory);

/* 学习结果 TSV 导出/导入（应用\t中文票\t英文票\t上屏天\t上屏票\t更新时间）。 */
char *liana_app_mode_export(LianaAppMode *memory);
int32_t liana_app_mode_import(LianaAppMode *memory, const char *tsv);

/* 输入统计总结（全为计数，零内容）：返回指标 JSON，由调用方释放。
 * 最后四个参数是 E3 评估层：selections = 选词数，top1_hits = 实际首选命中，
 * base_top1_hits = 反事实首选命中（剔除学习修正的基线排序），reselects = 重选次数；
 * 输出含 top1_rate / base_top1_rate / reselect_rate（百分数，无选词时为 0）。 */
char *liana_stats_digest_json(uint64_t chars, uint64_t keys, uint64_t deletes,
                                  uint64_t enters, uint64_t saved_keys,
                                  uint64_t voice_chars, uint64_t active_secs,
                                  uint64_t stare_max_secs, uint64_t selections,
                                  uint64_t top1_hits, uint64_t base_top1_hits,
                                  uint64_t reselects);

/* 插件包扫描（皮肤/桌宠/词典声明式数据包，零代码执行）：
 * 返回目录 JSON {"packs":[...],"errors":[...]}，由调用方释放。 */
char *liana_plugin_scan_json(const char *dir);

/* 知你自进化（ADR-0008 决策层）：上下文赌动机账本，全本地可解释。
 * reward_x100：100 选词 / 150 重选 / -200 删除 / 60 次选。 */
LianaEvolution *liana_evolution_new(void);
void liana_evolution_free(LianaEvolution *memory);

int32_t liana_evolution_reward(LianaEvolution *memory, const char *word,
                                   const char *lex_window, const char *app,
                                   uint32_t hour, int32_t reward_x100, uint64_t now);

/* 候选重排：输入 [{"text":..,"score":..},...]，输出按修正后分降序
 * [{"text":..,"score":..,"delta":..},...]，由调用方释放。 */
char *liana_evolution_adjust_json(LianaEvolution *memory, const char *candidates_json,
                                      const char *lex_window, const char *app,
                                      uint32_t hour, uint64_t now);

/* 决策轨道：[{"feature":..,"affinity":..},...]，由调用方释放。 */
char *liana_evolution_explain_json(LianaEvolution *memory, const char *word,
                                       const char *lex_window, const char *app,
                                       uint32_t hour, uint64_t now);

/* 学习账本 TSV 导出/导入与清空。 */
char *liana_evolution_export(LianaEvolution *memory);
int32_t liana_evolution_import(LianaEvolution *memory, const char *tsv);
void liana_evolution_forget_all(LianaEvolution *memory);

/* 知你教学层接线（ADR-0008 E1）：会话内的选词/删除序列 → 共享账本奖励，
 * 候选排序自动接 adjust（仅同层重排，封顶 ±3）。账本为进程单例，
 * 经任意会话读写；持久化由前端负责。 */

/* 同步决策上下文与开关（会话激活时调用）：app 可为 NULL/空串；
 * hour 0-23；enabled 非 0 开学习；now 为 Unix 秒（兼作重排时钟）。返回 1 表示已设置。 */
int32_t liana_set_evolution_context(LianaSession *session, const char *app,
                                        uint32_t hour, int32_t enabled, uint64_t now);

/* 确认一次选词：必须在 liana_select 成功后调用。alt_rank 非 0 表示
 * 数字键选了第 2+ 候选（+0.6），否则 +1.0；删除后的窗口内重选自动记 +1.5。 */
int32_t liana_evolution_note_selection(LianaSession *session, int32_t alt_rank,
                                           uint64_t now);

/* 无组合态的删除键：按「选了又删」记 −2 并武装重选期待；窗口外/重复删忽略。 */
int32_t liana_evolution_note_delete(LianaSession *session, uint64_t now);

/* 取走最近一次选词的评估（E3 反事实对比）：必须在 note_selection 之后调用。
 * 返回 {"actualTop1":..,"baseTop1":..,"reselect":..,"altRank":..}，由调用方释放；
 * actualTop1 = 选的是学习重排后的首选，baseTop1 = 基线（无学习）排序里也是首选，
 * 两者之差就是学习的收益；无待取评估时返回 NULL。 */
char *liana_evolution_eval_json(LianaSession *session);

/* 共享账本 TSV 导出/导入/清空（格式与 E0 独立句柄一致）。 */
char *liana_evolution_session_export(LianaSession *session);
int32_t liana_evolution_session_import(LianaSession *session, const char *tsv);
void liana_evolution_session_forget(LianaSession *session);

/* 知你喂食层（ADR-0008 E2）：文档 → 术语提炼 → 营养库。
 * 营养词获得词典级加分与按键召回（内核按词典单字读音派生拼音串），
 * 忘记即全部效果消失。 */

/* 术语提炼（纯函数，不经会话）：输入文档文本，输出
 * [{"term":..,"count":..},...]（复现次数降序，上限 50），由调用方释放。 */
char *liana_feed_extract_json(const char *text);

/* 喂入一条营养词；strength 为文档内复现次数（>=1），now 为 Unix 秒。
 * 返回 1 表示已入库（重复喂同一词：强度累加、出处与时间刷新）。 */
int32_t liana_nutrition_add(LianaSession *session, const char *term,
                                const char *source, uint32_t strength, uint64_t now);

/* 营养库列举（按加入时间倒序）：[{"term":..,"keys":..,"source":..,
 * "strength":..,"addedAt":..},...]，由调用方释放。 */
char *liana_nutrition_list_json(LianaSession *session);

/* 忘记一条营养词：返回 1 表示存在过并已删除。 */
int32_t liana_nutrition_forget(LianaSession *session, const char *term);

/* 清空营养库。 */
void liana_nutrition_forget_all(LianaSession *session);

/* 营养库 TSV 导出/导入（词\t按键串\t出处\t强度\t加入时间）；导入返回行数。 */
char *liana_nutrition_export(LianaSession *session);
int32_t liana_nutrition_import(LianaSession *session, const char *tsv);

/* 版本字符串（静态，勿释放）。 */
const char *liana_version(void);

#ifdef __cplusplus
}
#endif

#endif /* LIANA_H */
