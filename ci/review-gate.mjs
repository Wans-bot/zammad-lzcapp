#!/usr/bin/env node
// 审核闸门：若该应用已有「待审」审核单，则跳过本次自动发布，避免每次运行都取消并重建审核单。
//
// 背景：ca-x action 的 skip_if_version_exists 只比对**已在线版本**，不知道「待审」状态。
// 按计划每天跑的话，同一版本会被反复提交，前一张审核单被系统取消 → 永远等不到审核结果。
//
// 用法: node ci/review-gate.mjs <package>
// 环境: LZC_USER_TOKEN（开发者 token，CI 里就是 secrets.LAZYCAT_TOKEN）
// 输出: $GITHUB_OUTPUT 的 skip=true|false
import fs from 'node:fs';

const API = 'https://appstore.api.lazycat.cloud/api/v3/developer';
const pkg = process.argv[2];
const TOKEN = process.env.LZC_USER_TOKEN || '';
const OUT = process.env.GITHUB_OUTPUT;

function emit(skip, why) {
  console.log(`[review-gate] skip=${skip} — ${why}`);
  if (OUT) fs.appendFileSync(OUT, `skip=${skip}\n`);
  process.exit(0);
}

// ── 黑名单硬闸（最高优先级，不依赖 token）─────────────────────────
// 权威来源：/lzcapp/document/智能体知识库/records/lpk-selection-preference-and-blacklist.md
// 命中即拒绝提交官方商店。修改黑名单必须同步更新所有仓库的副本。
const BLACKLIST = new Set([
  'librenms', 'zabbix', 'wazuh', 'openmetadata', 'ragflow', 'mlflow',
  'openproject-ce', 'taiga', 'jimureport', 'glpi', 'ocs-inventory', 'osticket',
  'mantisbt', 'phpipam', 'opensourcepos', 'orangehrm', 'flarum-forum', 'nodebb',
  'zulip', 'ente', 'romm-hub', 'azuracast', 'wizarr', 'kolibri', 'humhub', 'fuxa',
  'relaydesk', 'tick-stock-panel', 'podfetch1', 'loomio', 'wavelog', 'offen',
  'perler-beads', 'umap', 'llamafactory', 'poster-design', 'hindsight', 'picimpact',
  'xzs', 'evcc1', 'bambuddy1',
]);
const shortId = String(pkg).replace(/^cloud\.lazycat\.apps?\./, '');
if (BLACKLIST.has(shortId)) {
  console.error(
    `[review-gate] ❌ 拒绝发布：${pkg} 命中黑名单（${shortId}）。\n` +
    `  依据 records/lpk-selection-preference-and-blacklist.md —— 该应用禁止提交官方商店。\n` +
    `  若确属误判，请先修改黑名单文件并同步更新本脚本，不要绕过闸门。`
  );
  process.exit(1);
}

// tag 推送是显式发布意图，绕过闸门
if (process.env.GITHUB_EVENT_NAME === 'push') emit(false, 'tag 推送，按显式意图发布');
if (!pkg) emit(false, '未提供 package，放行');
if (!TOKEN) emit(false, '缺少 LZC_USER_TOKEN，放行（无法判断待审状态）');

const HEAD = { 'X-User-Token': TOKEN, Cookie: `userToken=${TOKEN}`, 'Content-Type': 'application/json' };

try {
  let list;
  for (let i = 0; i < 3; i++) {
    const r = await fetch(`${API}/app/list?size=200`, { headers: HEAD, signal: AbortSignal.timeout(30000) });
    const t = await r.text();
    if (r.status >= 400) throw new Error(`HTTP ${r.status} ${t.slice(0, 120)}`);
    list = JSON.parse(t);
    break;
  }
  const apps = list.items || list.list || (Array.isArray(list) ? list : []);
  const app = apps.find((a) => a && a.package === pkg);
  if (!app) emit(false, `应用 ${pkg} 尚无建档记录，放行让 action 处理`);

  const rv = app.review;
  if (rv && String(rv.status) === '0') {
    emit(true, `已有待审审核单 #${rv.id}（提交于 ${rv.created_at || '?'}），等审核出结果再发`);
  }
  emit(false, `当前没有待审审核单（最近一张 #${rv && rv.id} 状态 ${rv && rv.status}），可以发布`);
} catch (e) {
  emit(false, `查询失败（${e.message}），放行以免挡住自动更新`);
}
