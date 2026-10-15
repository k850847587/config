// 手机机场私有 DNS：每机场独立 last-good；失败不清空有效数据。
// psnFile：逗号分隔文件名或 JSON 数组。只维护需要私有 DNS 的机场。
// 使用完整节点域名，避免粗暴截取最后两段误伤 co.uk 等公共后缀。
// 仅修改生成结果 dns.proxy-server-nameserver-policy，不修改模板和其他 DNS/规则。
const log = $substore;
const args = typeof $arguments === 'object' && $arguments ? $arguments : {};
const fileName = typeof $file === 'object' && $file?.name ? $file.name : 'config-phone.yaml';
const cacheKey = 'kzz.phone-private-dns.v2.' + encodeURIComponent(fileName);
const yamlLib = ProxyUtils.yaml;
const warnings = message => log.info('[私有DNS] ' + message);
const unique = list => [...new Set(list)];
const plain = obj => obj && typeof obj === 'object' && !Array.isArray(obj);

function hostName(value) {
  if (typeof value !== 'string') return null;
  const host = value.trim().toLowerCase().replace(/\.$/, '');
  if (!host || host.includes(':') || /^\d+(\.\d+){3}$/.test(host)) return null;
  if (host.length > 253 || !host.includes('.')) return null;
  const labels = host.split('.');
  if (!labels.every(x => x.length > 0 && x.length <= 63 && /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(x))) return null;
  if (/^\d+$/.test(labels.at(-1))) return null;
  return host;
}
function resolver(value) {
  if (typeof value !== 'string') return null;
  const text = value.trim();
  if (!text || /[\s<>]/.test(text)) return null;
  if (text === 'system') return text;
  try {
    if (text.includes('://')) {
      const u = new URL(text);
      if (!['udp:', 'tcp:', 'tls:', 'https:', 'http:', 'quic:', 'h3:'].includes(u.protocol) || !u.hostname) return null;
      return text;
    }
    // Plain DNS address (IPv4/IPv6/domain), optionally with port/selector.
    const address = text.split('#')[0];
    const ipv4 = address.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)(?::(\d+))?$/);
    if (ipv4) return ipv4.slice(1,5).every(x => Number(x) <= 255) && (!ipv4[5] || (+ipv4[5] > 0 && +ipv4[5] <= 65535)) ? text : null;
    if (address.includes(':')) {
      new URL('http://' + (address.startsWith('[') ? address : '[' + address + ']'));
      return text;
    }
    return hostName(address) ? text : null;
  } catch (_) { return null; }
}
function snapshot(value) {
  if (!plain(value) || !Array.isArray(value.domains) || !Array.isArray(value.resolvers)) return null;
  const domains = unique(value.domains.map(hostName).filter(Boolean)).sort();
  const resolvers = unique(value.resolvers.map(resolver).filter(Boolean));
  // A partial/corrupt response must never replace the last complete snapshot.
  if (!domains.length || !resolvers.length || domains.length !== unique(value.domains).length || resolvers.length !== unique(value.resolvers).length) return null;
  return { domains, resolvers, updatedAt: typeof value.updatedAt === 'string' ? value.updatedAt : '' };
}
function parseFiles(input) {
  let list = input;
  if (typeof list === 'string') {
    const text = list.trim();
    if (text.startsWith('[')) {
      try { list = JSON.parse(text); } catch (_) { throw new Error('psnFile 的 JSON 数组格式错误'); }
    } else list = text.split(',');
  }
  if (!Array.isArray(list)) throw new Error('psnFile 应为文件名列表');
  list = unique(list.filter(x => typeof x === 'string').map(x => x.trim()).filter(Boolean));
  if (!list.length) throw new Error('psnFile 不能为空');
  if (list.includes(fileName)) throw new Error('psnFile 不能引用当前手机文件，避免递归');
  return list;
}
function unwrapRaw(raw) {
  let value = raw;
  for (let i = 0; i < 4; i++) {
    if (Array.isArray(value)) {
      const values = value.filter(x => typeof x === 'string' && x.trim());
      if (values.length !== 1) throw new Error('原始文件内容数量异常');
      value = values[0]; continue;
    }
    if (typeof value !== 'string' || !value.trim()) throw new Error('原始文件为空');
    const text = value.trim();
    if (/^(?:<!doctype\s+html|<html\b|<head\b|<body\b)/i.test(text)) throw new Error('收到 HTML 而非订阅');
    if (text.startsWith('[') || text.startsWith('"')) {
      try { value = JSON.parse(text); continue; } catch (_) { /* YAML validation below */ }
    }
    return text;
  }
  throw new Error('原始文件包装格式异常');
}
function extract(raw) {
  const doc = yamlLib.safeLoad(unwrapRaw(raw));
  if (!plain(doc) || !plain(doc.dns) || !Array.isArray(doc.proxies)) throw new Error('缺少 dns/proxies');
  const dns = doc.dns['proxy-server-nameserver'];
  const list = Array.isArray(dns) ? dns : [dns];
  const resolvers = list.map(resolver);
  if (!list.length || resolvers.some(x => !x)) throw new Error('私有 DNS 缺失或格式无效');
  const domains = [];
  let badServers = 0;
  for (const proxy of doc.proxies) {
    const server = proxy?.server;
    if (typeof server !== 'string' || !server.trim()) { badServers++; continue; }
    const host = hostName(server);
    if (host) domains.push(host);
    else {
      // IP 节点无需 DNS；非法主机名则拒绝这份不完整数据。
      const ip = server.trim();
      if (!(/^\d+(\.\d+){3}$/.test(ip) || ip.includes(':'))) badServers++;
    }
  }
  if (badServers) throw new Error('节点 server 不完整');
  const result = snapshot({ domains: unique(domains), resolvers: unique(resolvers), updatedAt: new Date().toISOString() });
  if (!result) throw new Error('没有可用的域名与私有 DNS 配对');
  return result;
}
async function timedProduce(name) {
  let timer;
  try {
    return await Promise.race([
      produceArtifact({ type: 'file', name, produceType: 'raw' }),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('读取超时')), 20000); })
    ]);
  } finally { clearTimeout(timer); }
}

// 模板自身错误必须显式报错；机场失败则隔离，不把配置输出成残缺 YAML。
const config = yamlLib.safeLoad($content);
if (!plain(config)) throw new Error('手机模板不是 YAML 配置对象');
if (config.dns != null && !plain(config.dns)) throw new Error('模板 dns 不是映射');
const dns = config.dns || {};
const manual = dns['proxy-server-nameserver-policy'] || {};
if (!plain(manual)) throw new Error('模板 proxy-server-nameserver-policy 不是映射');
const files = parseFiles(args.psnFile || '光速云-RAW.yaml');
let stored = { version: 2, airports: {} };
try {
  const raw = log.read(cacheKey);
  const data = typeof raw === 'string' ? JSON.parse(raw) : raw;
  if (plain(data) && data.version === 2 && plain(data.airports)) stored = data;
} catch (_) { warnings('历史缓存损坏或无法读取，本次仍继续处理'); }
const nextAirports = { ...stored.airports };
const results = [];
let fresh = 0, reused = 0, skipped = 0;
for (const name of files) {
  let data = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    try { data = extract(await timedProduce(name)); break; }
    catch (_) { /* Do not log upstream exceptions: may contain subscription credentials. */ }
  }
  if (data) {
    fresh++; nextAirports[name] = data;
    warnings(`${name}：读取成功（${data.domains.length} 个节点域名）`);
  } else {
    data = snapshot(stored.airports[name]);
    if (data) { reused++; warnings(`${name}：读取失败，沿用上次成功数据（${data.updatedAt || '时间未知'}）`); }
    else { skipped++; warnings(`${name}：读取失败且无有效历史，跳过，不影响其他机场`); }
  }
  if (data) results.push({ name, ...data });
}
const generated = new Map();
const conflicts = new Set();
for (const item of results) {
  for (const domain of item.domains) {
    const signature = [...item.resolvers].sort().join('\n');
    const previous = generated.get(domain);
    if (previous && previous.signature !== signature) { conflicts.add(domain); continue; }
    generated.set(domain, { signature, resolvers: item.resolvers });
  }
}
const policy = { ...manual };
for (const [domain, item] of generated) {
  if (conflicts.has(domain)) continue;
  // Explicit template policy wins for the same exact key.
  if (!Object.prototype.hasOwnProperty.call(policy, domain)) policy[domain] = item.resolvers;
}
if (conflicts.size) warnings(`有 ${conflicts.size} 个跨机场域名 DNS 冲突，未自动覆盖，需人工确认`);
// All failures with no history leave original content byte-for-byte intact.
if (generated.size > conflicts.size) {
  config.dns = dns;
  dns['proxy-server-nameserver-policy'] = policy;
  $content = yamlLib.safeDump(config, { lineWidth: -1, forceQuotes: true });
}
if (fresh) {
  try {
    log.write({ version: 2, airports: nextAirports }, cacheKey);
    if (!log.read(cacheKey)) warnings('缓存写入后无法读回；下次失败可能无法使用历史');
  } catch (_) { warnings('缓存持久化失败；本次有效结果仍可输出'); }
}
warnings(`完成：成功 ${fresh}，沿用 ${reused}，跳过 ${skipped}，注入 ${generated.size - conflicts.size} 个节点域名策略`);

