/**
 * 语言清单：唯一来源是内核注册表（NAPI 的 `liana.languages()` → `liana_languages()`）。
 *
 * 以前这里写死 `['pinyin', 'en']`，内核加了 ja/ko/es 之后菜单跟不上了。
 * 现在只做三件事：解析 JSON、缺失时回退、排菜单顺序。纯字符串/JSON 逻辑，
 * 不碰 SDK，所以能拿 node 直接跑测试（见 platforms/harmonyos/test/）。
 */

export interface LianaLanguage {
  id: string;
  label: string;
  policy: string;
}

/**
 * 内核取不到清单时的兜底：与 `builtin_languages()` 的 9 项、顺序、policy 一一对应。
 * 菜单可以少一项，不能变空——空菜单等于键盘不能用。
 */
export const FALLBACK_LANGUAGES: LianaLanguage[] = [
  { id: 'pinyin', label: '拼音', policy: 'ascii' },
  { id: 'flypy', label: '小鹤双拼', policy: 'ascii' },
  { id: 'mspy', label: '微软双拼', policy: 'ascii' },
  { id: 'zrm', label: '自然码', policy: 'ascii' },
  { id: 'emoji', label: '表情', policy: 'ascii' },
  { id: 'en', label: 'English', policy: 'ascii' },
  { id: 'es', label: 'Español', policy: 'unicode' },
  { id: 'ja', label: '日本語', policy: 'ascii' },
  { id: 'ko', label: '한국어', policy: 'ascii' },
];

/**
 * 解析 `[{"id","label","policy"}]`。
 * 缺 id 的项丢弃、重复 id 保留第一个、缺 label 用 id 顶、未知字段忽略、
 * 坏输入返回空数组（由 loadLanguages 兜底）。
 */
export function parseLanguages(json: string | null | undefined): LianaLanguage[] {
  if (typeof json !== 'string' || json.trim().length === 0) {
    return [];
  }
  let rows: LianaLanguage[] = [];
  try {
    const parsed = JSON.parse(json) as LianaLanguage[];
    if (!Array.isArray(parsed)) {
      return [];
    }
    rows = parsed;
  } catch (e) {
    return [];
  }
  const seen: Set<string> = new Set<string>();
  const out: LianaLanguage[] = [];
  for (const row of rows) {
    if (row === null || row === undefined) {
      continue;
    }
    const rawId = row.id;
    const id = typeof rawId === 'string' ? rawId.trim() : '';
    if (id.length === 0 || seen.has(id)) {
      continue;
    }
    seen.add(id);
    const rawLabel = row.label;
    const label = typeof rawLabel === 'string' && rawLabel.trim().length > 0 ? rawLabel.trim() : id;
    const rawPolicy = row.policy;
    const policy = typeof rawPolicy === 'string' ? rawPolicy : '';
    out.push({ id: id, label: label, policy: policy });
  }
  return out;
}

/** 内核优先、回退兜底。 */
export function loadLanguages(json: string | null | undefined): LianaLanguage[] {
  const parsed = parseLanguages(json);
  return parsed.length > 0 ? parsed : FALLBACK_LANGUAGES;
}

/** 菜单顺序：内核顺序在前，平台自有方案殿后，重复 id 去掉。 */
export function menuOrder(kernel: LianaLanguage[], platformIds: string[]): string[] {
  const seen: Set<string> = new Set<string>();
  const out: string[] = [];
  for (const language of kernel) {
    if (!seen.has(language.id)) {
      seen.add(language.id);
      out.push(language.id);
    }
  }
  for (const id of platformIds) {
    if (!seen.has(id)) {
      seen.add(id);
      out.push(id);
    }
  }
  return out;
}

/** 当前 id 在清单里的下一项（循环切语言）。 */
export function nextLanguageId(ids: string[], current: string): string {
  if (ids.length === 0) {
    return current;
  }
  const index = ids.indexOf(current);
  return ids[(index + 1) % ids.length];
}
