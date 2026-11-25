// 鸿蒙菜单清单的纯逻辑测试：node --experimental-strip-types 直接跑 .ts，不需要 DevEco。
// 覆盖解析 / 回退 / 菜单顺序 / 循环切换；ArkTS 侧只是把这些函数接到 NAPI 上。
import assert from 'node:assert/strict';
import {
  FALLBACK_LANGUAGES,
  loadLanguages,
  menuOrder,
  nextLanguageId,
  parseLanguages,
} from '../entry/src/main/ets/inputmethod/LanguageList.ts';

// 内核真实输出：四个中文在前，其余按 id 字典序（builtin_languages()）。
const KERNEL_JSON = JSON.stringify([
  { id: 'pinyin', label: '拼音', policy: 'ascii' },
  { id: 'flypy', label: '小鹤双拼', policy: 'ascii' },
  { id: 'mspy', label: '微软双拼', policy: 'ascii' },
  { id: 'zrm', label: '自然码', policy: 'ascii' },
  { id: 'emoji', label: '表情', policy: 'ascii' },
  { id: 'en', label: 'English', policy: 'ascii' },
  { id: 'es', label: 'Español', policy: 'unicode' },
  { id: 'ja', label: '日本語', policy: 'ascii' },
  { id: 'ko', label: '한국어', policy: 'ascii' },
]);

const parsed = parseLanguages(KERNEL_JSON);
assert.equal(parsed.length, 9, `应解析出 9 项，实际 ${parsed.length}`);
assert.deepEqual(
  parsed.map((x) => x.id),
  ['pinyin', 'flypy', 'mspy', 'zrm', 'emoji', 'en', 'es', 'ja', 'ko'],
  '内核顺序被改写',
);
assert.equal(parsed[7].label, '日本語');
assert.equal(parsed[6].policy, 'unicode', '重音语言必须是 unicode 闸门');

for (const bad of [null, undefined, '', '   ', '[]', '{}', 'not json', '<html>', '[{"label":"缺 id"}]']) {
  assert.equal(parseLanguages(bad).length, 0, `坏输入应返回空：${String(bad)}`);
}

const messy = parseLanguages(
  '[{"id":"ja","policy":"ascii"},{"id":"ja","label":"重复"},{"id":"ko","label":"","policy":"x"},{"id":"es","label":"Español","extra":1}]',
);
assert.deepEqual(messy.map((x) => x.id), ['ja', 'ko', 'es'], '去重或保序不对');
assert.equal(messy[0].label, 'ja', '缺 label 应用 id 顶上');
assert.equal(messy[1].label, 'ko', '空 label 应用 id 顶上');

// 回退：内核符号缺失（老 .so）或返回坏 JSON 时菜单不能空。
assert.deepEqual(loadLanguages(null), FALLBACK_LANGUAGES, '内核没给清单时必须回退');
assert.deepEqual(loadLanguages('garbage'), FALLBACK_LANGUAGES, '坏 JSON 必须回退');
assert.deepEqual(
  loadLanguages(KERNEL_JSON).map((x) => x.id),
  FALLBACK_LANGUAGES.map((x) => x.id),
  '回退清单与内核清单的 id/顺序必须一致，否则两边菜单不一样',
);
for (const id of ['pinyin', 'flypy', 'mspy', 'zrm', 'emoji', 'en', 'es', 'ja', 'ko']) {
  assert.ok(FALLBACK_LANGUAGES.some((x) => x.id === id), `回退清单缺 ${id}`);
}

// 菜单顺序：内核在前，平台方案殿后，撞名只留一个。
assert.deepEqual(menuOrder(parsed, ['t9', 'wubi', 'handwriting']), [
  'pinyin', 'flypy', 'mspy', 'zrm', 'emoji', 'en', 'es', 'ja', 'ko', 't9', 'wubi', 'handwriting',
]);
const clash = menuOrder(parsed, ['ja', 't9']);
assert.equal(clash.filter((x) => x === 'ja').length, 1, '重复 id 应只留内核那一个');
assert.equal(clash[clash.length - 1], 't9');

// 模式键循环切换：9 门语言都到得了，末尾回到第一项。
const ids = menuOrder(parsed, []);
assert.equal(nextLanguageId(ids, 'pinyin'), 'flypy');
assert.equal(nextLanguageId(ids, 'ko'), 'pinyin', '最后一项应绕回第一项');
assert.equal(nextLanguageId(ids, 'unknown'), 'pinyin', '未知当前值从第一项开始');
assert.equal(nextLanguageId([], 'pinyin'), 'pinyin', '空清单不许崩');

console.log('鸿蒙语言清单：解析 / 回退 / 菜单顺序 / 循环切换 passed');
