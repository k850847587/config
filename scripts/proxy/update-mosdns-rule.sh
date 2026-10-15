#!/bin/sh
printf '————————————执行开始(%s)————————————\n' "$(date '+%Y-%m-%d %H:%M')"

# ==============================================================================
# update-mosdns-rule.sh  （v4：默认链路归还 config.yaml，生成文件只放机场相关）
#
# 只维护「需要机场私有 DNS 的机场」：这类机场在脚本的 AIRPORTS 里一行一个。
# 生成 airports_gen.yaml，只包含：
#   - 每个可用机场：forward_<别名>（机场私有 DNS）/ cache_<别名> /
#     match_specific_domains_<别名> / handle_specific_<别名>
#   - 机场分发链 airport_router（config.yaml 的 main_sequence 第一步 jump 到它）
# 默认缓存 cache_default / 默认上游 upstream_default（阿里 DNS）/ 主链 main_sequence
# 都在 config.yaml 里手写，本脚本**不生成、也不改动** config.yaml。
#
# 为什么默认链路必须留在 config.yaml：mosdns 的 include 是「被包含文件先加载、主文件后加载」，
# 被包含文件里的插件**引用不到**主文件的插件；反过来（主文件引用被包含的 airport_router）是通的，
# 所以分发链放生成文件、默认链路放 config.yaml，方向刚好正确。
#
# AIRPORTS 每行：别名|订阅URL[|lazy_cache_ttl][|标记]
#   第 3 段纯数字 = 该机场缓存的 lazy_cache_ttl（秒）；写非数字（如 ipv6）会被当成标记
#   标记 ipv6 = 「这个机场有 IPv6 节点」→ 该机场专属链里**不 reject AAAA(qtype 28)**
#   （没标 ipv6 的机场默认会 reject AAAA，客户端只拿到 IPv4 节点）
#
# 容错（针对 substore 拉不到订阅返回 500 / HTML 错误页）：
#   1) 单个机场拉取失败 → 从现有生成文件恢复上次成功的 DNS，沿用历史数据；连旧数据都没有 → 跳过该机场。
#   2) 所有机场都没数据 → airport_router 生成成一个空操作，请求直接落回 config.yaml 的
#      默认链路（默认缓存 + 阿里上游），mosdns 照常启动（不报错、不重启失败）。
#   3) 生成 → YAML 校验 + 引用完整性校验 → 临时容器真启动预检 → 全过才替换。
#   4) 替换前备份，且**只保留最新一份** .bak-*（不累计）。
#   5) 只有内容真变了才重启；重启后查状态/重启计数/日志，不健康自动回滚。
#   6) 单个机场失败不影响退出码（exit 0）。
# ==============================================================================


# ==============================
# 0. 基础环境与依赖检查
# ==============================

check_and_install_deps() {
    MISSING_PKGS=""

    command -v curl >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS curl"
    command -v python3 >/dev/null 2>&1 || MISSING_PKGS="$MISSING_PKGS python3"

    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import yaml" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            MISSING_PKGS="$MISSING_PKGS py3-yaml"
        fi
    fi

    if [ -n "$MISSING_PKGS" ]; then
        echo "检测到缺少依赖组件:$MISSING_PKGS，尝试自动安装..."
        if command -v apk >/dev/null 2>&1; then
            apk update && apk add $MISSING_PKGS
        elif command -v apt-get >/dev/null 2>&1; then
            APT_PKGS=$(echo "$MISSING_PKGS" | sed 's/py3-yaml/python3-yaml/g')
            apt-get update && apt-get install -y $APT_PKGS
        elif command -v dnf >/dev/null 2>&1; then
            DNF_PKGS=$(echo "$MISSING_PKGS" | sed 's/py3-yaml/python3-pyyaml/g')
            dnf install -y $DNF_PKGS
        elif command -v yum >/dev/null 2>&1; then
            YUM_PKGS=$(echo "$MISSING_PKGS" | sed 's/py3-yaml/PyYAML/g')
            yum install -y $YUM_PKGS
        else
            echo "⚠️ 未找到支持的包管理器，请手动安装以下组件:$MISSING_PKGS"
            exit 1
        fi
    fi
}

check_and_install_deps


# ==============================
# 1. 本地路径与可调参数
# ==============================
CONTAINER_NAME="mosdns"
WORK_DIR="/vol2/@team/docker/proxy/mosdns"
RULES_DIR="$WORK_DIR/rules"                     # 每个机场的节点域名（domain_set 用）
TMP_DIR=$(mktemp -d /tmp/mosdns-run.XXXXXX) || exit 1
STATE_DIR="$TMP_DIR/state"                      # 私有 DNS 仅本次执行使用
trap 'rc=$?; trap - EXIT; rm -rf "$TMP_DIR"; printf "————————————执行完毕(%s)————————————\n" "$(date +"%Y-%m-%d %H:%M")"; exit "$rc"' EXIT
trap 'exit 1' HUP INT TERM
GEN_FILE="$WORK_DIR/airports_gen.yaml"          # 生成的配置文件（config.yaml 里 include 它）

# 拉取与缓存参数
RETRY_TIMES=3                                   # 单个订阅最多尝试次数
RETRY_DELAY=5                                   # 每次重试间隔（秒）
CACHE_SIZE=500                                   # 每个机场独立缓存条数
CACHE_LAZY_TTL=3600                                # 机场缓存过期后是否继续用旧值（秒，0=不用）

# ------------------------------
# 机场列表：别名|订阅URL[|lazy_cache_ttl][|标记]   （只写需要「机场私有 DNS」的机场）
#   - 别名只用字母数字下划线（不要空格）
#   - URL 用 substore 里对应机场的 RAW 文件（能直接吐出含 proxies: 的 YAML）
#   - 第 3 段可选：该机场独立缓存的 lazy_cache_ttl（秒）；写非数字（如 ipv6）则当作标记
#   - 第 4 段可选：标记，逗号分隔；目前支持 ipv6 = 该机场有 IPv6 节点，不 reject AAAA
#     例：airport_c|${SUB_PREFIX}/xxx-RAW.yaml|1800|ipv6   ← 缓存留用 30 分钟 + 保留 AAAA
# 参与分流的机场（域名+DNS 都拉到）才会生成一整套插件；拉不到的机场一个插件都不生成，
# 数量自动跟着「实际可用机场数」走。全拉不到时 airport_router 是空操作，请求落回 config.yaml 的默认链路。
# ------------------------------
SUB_PREFIX="https://example.com/REPLACE_WITH_SUBSTORE_PREFIX"

AIRPORTS="
airport_a|${SUB_PREFIX}/%E5%85%89%E9%80%9F%E4%BA%91-RAW.yaml
airport_b|${SUB_PREFIX}/crush-raw.yaml|ipv6
"
# 再加机场就这样追加一行（别名不重复）：
# airport_c|${SUB_PREFIX}/xxxx-RAW.yaml|ipv6


mkdir -p "$TMP_DIR" "$RULES_DIR" "$STATE_DIR"
rm -f "$TMP_DIR"/*.new "$RULES_DIR"/.*.new "$STATE_DIR"/.*.new 2>/dev/null

# 从已生效生成文件恢复 last-good DNS，不需要常驻 state 目录。
python3 - "$GEN_FILE" "$STATE_DIR" <<'RESTORE_DNS'
import sys, os, yaml
try:
    cfg = yaml.safe_load(open(sys.argv[1])) or {}
    for p in cfg.get("plugins", []):
        tag = p.get("tag", "")
        if p.get("type") == "forward" and tag.startswith("forward_"):
            name = tag[len("forward_"):]
            if not name.replace("_", "").isalnum():
                continue
            values = [str(u["addr"]) for u in p.get("args", {}).get("upstreams", []) if u.get("addr")]
            if values:
                with open(os.path.join(sys.argv[2], "dns_" + name + ".txt"), "w") as f:
                    f.write("\n".join(values) + "\n")
except FileNotFoundError:
    pass
except Exception as e:
    print("恢复历史 DNS 失败，本次仍尝试拉取订阅：", e)
RESTORE_DNS

UPDATE_TIME=$(date "+%Y-%m-%d %H:%M:%S")

# 清理超过 1 天的历史临时目录（上次被杀/崩溃留下的；老版本留在 /tmp 的也一起扫掉）
find "$WORK_DIR" -maxdepth 1 -name '.mosdns_tmp.*' -type d -mtime +0 -exec rm -rf {} + 2>/dev/null
find /tmp -maxdepth 1 -name 'mosdns_tmp.*' -type d -mtime +0 -exec rm -rf {} + 2>/dev/null

echo "========================================="
echo "更新 mosdns 机场分流规则  $UPDATE_TIME"
echo "========================================="


# ==============================
# 2. 逐个机场拉取（失败即降级，绝不中断）
# ==============================

ACTIVE_FILE="$TMP_DIR/active.txt"
SUMMARY_TEXT=""
: > "$ACTIVE_FILE"

SNAP_BEFORE=$(cat "$RULES_DIR"/airport_domains_*.txt "$STATE_DIR"/dns_*.txt 2>/dev/null | cksum)

for ENTRY in $AIRPORTS; do
    NAME=$(echo "$ENTRY" | cut -d'|' -f1)
    SUB_URL=$(echo "$ENTRY" | cut -d'|' -f2)
    FIELD3=$(echo "$ENTRY" | cut -d'|' -f3)
    FIELD4=$(echo "$ENTRY" | cut -d'|' -f4)
    # 第 3 段：纯数字 = lazy_cache_ttl；非数字（如 ipv6）= 标记
    AP_TTL="$CACHE_LAZY_TTL"
    AP_FLAGS="$FIELD4"
    case "$FIELD3" in
        '') ;;
        *[!0-9]*) AP_FLAGS="${AP_FLAGS}${AP_FLAGS:+,}${FIELD3}" ;;
        *) AP_TTL="$FIELD3" ;;
    esac
    AP_FLAGS=$(echo "$AP_FLAGS" | tr 'A-Z' 'a-z' | tr -d ' ')
    [ -z "$NAME" ] && continue
    [ -z "$SUB_URL" ] && continue

    echo "-----------------------------------------"
    echo "处理机场 [$NAME]..."

    DOMAIN_FILE="$RULES_DIR/airport_domains_${NAME}.txt"
    DNS_STATE_FILE="$STATE_DIR/dns_${NAME}.txt"

    SUB_FILE="$TMP_DIR/sub_${NAME}.txt"
    : > "$SUB_FILE"
    STAGE_DOMAIN="$RULES_DIR/.airport_domains_${NAME}.txt.new"
    STAGE_DNS="$STATE_DIR/.dns_${NAME}.txt.new"

    # ---- 2.1 带重试下载：HTTP 非 200 / 空文件 / HTML 错误页 都算失败 ----
    FETCH_OK=0
    CODE=""
    i=1
    while [ "$i" -le "$RETRY_TIMES" ]; do
        mkdir -p "$TMP_DIR" 2>/dev/null    # 兜底：万一临时目录被外部清掉，先补回来再写
        CODE=$(curl -s -L -A "ClashMeta" --connect-timeout 8 -m 40 -o "$SUB_FILE" -w '%{http_code}' "$SUB_URL")
        if [ "$CODE" = "200" ] && [ -s "$SUB_FILE" ] \
           && ! head -c 300 "$SUB_FILE" | grep -qiE '<!doctype html|<html'; then
            FETCH_OK=1
            break
        fi
        echo "  ⚠️ 第 $i/$RETRY_TIMES 次拉取失败（http=$CODE，大小 $(wc -c < "$SUB_FILE" 2>/dev/null)B）"
        i=$((i + 1))
        [ "$i" -le "$RETRY_TIMES" ] && sleep "$RETRY_DELAY"
    done

    # ---- 2.2 解析：必须能解出非空 proxies 才算这次拉取有效 ----
    PARSE_OK=0
    if [ "$FETCH_OK" = "1" ]; then
        PARSE_RESULT=$(python3 - "$SUB_FILE" "$STAGE_DOMAIN" "$STAGE_DNS" <<'PY'
import sys, re, ipaddress, base64
try:
    import yaml
except Exception:
    print("FAIL|python3-yaml 缺失"); sys.exit(0)

sub_path, out_domains, out_dns = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(sub_path, "rb").read()

data = None
for attempt in ("yaml", "b64"):
    try:
        blob = raw if attempt == "yaml" else base64.b64decode(raw)
        data = yaml.safe_load(blob)
        if isinstance(data, dict):
            break
    except Exception:
        data = None

if not isinstance(data, dict):
    print("FAIL|内容不是合法 YAML（可能是错误页或被截断）"); sys.exit(0)

proxies = data.get("proxies") or []
if not isinstance(proxies, list) or len(proxies) == 0:
    print("FAIL|YAML 里没有 proxies（订阅为空或格式不对）"); sys.exit(0)

def format_dns(value):
    if not value:
        return None
    value = str(value).strip()
    if re.match(r'^(https|tls|udp|tcp)://', value, re.IGNORECASE):
        return value
    clean = re.split(r'[:#/\s]', value)[0]
    try:
        ipaddress.ip_address(clean)
        return value
    except Exception:
        return value

def root_domain(domain):
    if not domain:
        return None
    domain = str(domain).lower().strip()
    domain = re.split(r'[:#/\s]', domain)[0]
    try:
        ipaddress.ip_address(domain)
        return None
    except Exception:
        pass
    parts = domain.split(".")
    if len(parts) < 2:
        return None
    double_ext = {"com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn"}
    if len(parts) >= 3 and ".".join(parts[-2:]) in double_ext:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:])

dns_servers = (data.get("dns") or {}).get("proxy-server-nameserver") or []
if isinstance(dns_servers, str):
    dns_servers = [dns_servers]
dns_list = []
for s in dns_servers:
    f = format_dns(s)
    if f and f not in dns_list:
        dns_list.append(f)

domains = set()
for p in proxies:
    if isinstance(p, dict):
        d = root_domain(p.get("server"))
        if d:
            domains.add(d)

if not domains:
    print("FAIL|能解出 proxies 但没有可用域名（全是 IP？）"); sys.exit(0)

with open(out_domains, "w") as f:
    for d in sorted(domains):
        f.write(d + "\n")
with open(out_dns, "w") as f:
    for d in dns_list:
        f.write(d + "\n")

print("OK|%d|%d" % (len(domains), len(dns_list)))
PY
)
        case "$PARSE_RESULT" in
            OK\|*) PARSE_OK=1 ;;
            *) echo "  ⚠️ 解析失败：${PARSE_RESULT#FAIL|}" ;;
        esac
    fi

    # ---- 2.3 成功 → 原子替换；失败 → 沿用上次成功的数据 ----
    NEW_DOMAINS=0
    NEW_DNS=0
    if [ "$PARSE_OK" = "1" ]; then
        NEW_DOMAINS=$(wc -l < "$STAGE_DOMAIN" 2>/dev/null | tr -d ' ')
        NEW_DNS=$(wc -l < "$STAGE_DNS" 2>/dev/null | tr -d ' ')
        mv -f "$STAGE_DOMAIN" "$DOMAIN_FILE"
        mv -f "$STAGE_DNS" "$DNS_STATE_FILE"
        STATUS="✅ 本次更新"
    else
        if [ -s "$DOMAIN_FILE" ] && [ -s "$DNS_STATE_FILE" ]; then
            NEW_DOMAINS=$(wc -l < "$DOMAIN_FILE" | tr -d ' ')
            NEW_DNS=$(wc -l < "$DNS_STATE_FILE" | tr -d ' ')
            STATUS="♻️ 沿用上次成功的数据"
        else
            STATUS="⏭️ 跳过（无可用数据 → 该机场域名走默认上游）"
            [ -f "$DOMAIN_FILE" ] && [ ! -s "$DOMAIN_FILE" ] && rm -f "$DOMAIN_FILE"
            [ -f "$DNS_STATE_FILE" ] && [ ! -s "$DNS_STATE_FILE" ] && rm -f "$DNS_STATE_FILE"
        fi
    fi
    rm -f "$STAGE_DOMAIN" "$STAGE_DNS" 2>/dev/null

    # ---- 2.4 域名 + DNS 都齐才参与分流 ----
    if [ -s "$DOMAIN_FILE" ] && [ -s "$DNS_STATE_FILE" ]; then
        echo "$NAME|$DOMAIN_FILE|$DNS_STATE_FILE|$AP_TTL|$AP_FLAGS" >> "$ACTIVE_FILE"
        echo "  $STATUS  （节点域名 ${NEW_DOMAINS} 条 / 私有 DNS ${NEW_DNS} 条${AP_FLAGS:+ / 标记 ${AP_FLAGS}}）"
        SUMMARY_TEXT="${SUMMARY_TEXT}$(printf '%-12s %-34s %s\n' "$NAME" "$STATUS" "域名${NEW_DOMAINS}/DNS${NEW_DNS}${AP_FLAGS:+ [${AP_FLAGS}]}")
"
    else
        echo "  $STATUS"
        SUMMARY_TEXT="${SUMMARY_TEXT}$(printf '%-12s %-34s %s\n' "$NAME" "$STATUS" "未参与分流")
"
    fi
done

SNAP_AFTER=$(cat "$RULES_DIR"/airport_domains_*.txt "$STATE_DIR"/dns_*.txt 2>/dev/null | cksum)
[ "$SNAP_BEFORE" = "$SNAP_AFTER" ] || RULES_CHANGED=1


# ==============================
# 3. 生成 airports_gen.yaml（自洽：默认链路 + 各机场 + 主链）
# ==============================

echo "-----------------------------------------"
echo "生成 airports_gen.yaml..."

export TMP_DIR UPDATE_TIME CACHE_SIZE

GEN_RESULT=$(python3 - <<'PY'
import os, re, yaml

tmp = os.environ["TMP_DIR"]
cache_size = int(os.environ["CACHE_SIZE"])
update_time = os.environ["UPDATE_TIME"]
out_path = os.path.join(tmp, "airports_gen.yaml.new")

active = []
with open(os.path.join(tmp, "active.txt")) as f:
    for line in f:
        line = line.strip()
        if line:
            parts = line.split("|")
            name, domains_file, dns_file = parts[0], parts[1], parts[2]
            ttl = 0
            if len(parts) > 3 and parts[3].strip().isdigit():
                ttl = int(parts[3].strip())
            flags = parts[4].strip().lower() if len(parts) > 4 else ""
            ipv6 = "ipv6" in [x.strip() for x in flags.split(",") if x.strip()]
            active.append({"name": name, "domains": domains_file, "dns": dns_file,
                           "ttl": ttl, "ipv6": ipv6})

L = []
L += ["# 更新时间: %s" % update_time,
      "# 本文件由 update-mosdns-rule.sh 生成，勿手改（机场列表在脚本里的 AIRPORTS）",
      "# 内容：每个可用机场的 forward/缓存/域名集/处理链 + 机场分发链 airport_router",
      "# 默认缓存 cache_default / 默认上游 upstream_default / 主链 main_sequence 在 config.yaml 里（由它 include 本文件）。",
      "# 说明：所有机场都拉不到时 airport_router 是空操作，请求直接落回 config.yaml 的默认链路，mosdns 照常启动。",
      "plugins:"]

# ---------- 各机场：forward ----------
if active:
    L.append("  # ================= 机场私有 DNS 上游 =================")
    for ap in active:
        L += ["  - tag: forward_%s" % ap["name"],
              "    type: forward",
              "    args:",
              "      concurrent: 3",
              "      upstreams:"]
        with open(ap["dns"]) as f:
            for addr in [x.strip() for x in f if x.strip()]:
                L.append("        - addr: \"%s\"" % addr)
                if addr.lower().startswith("https"):
                    L += ["          enable_pipeline: true",
                          "          enable_http3: false",
                          "          bootstrap: 223.5.5.5",
                          "          bootstrap_version: 4",
                          "          idle_timeout: 30"]
        L.append("")
    L.append("  # ================= 机场独立缓存 =================")
    for ap in active:
        L += ["  - tag: cache_%s" % ap["name"],
              "    type: cache",
              "    args:",
              "      size: %d" % cache_size,
              "      lazy_cache_ttl: %d" % ap["ttl"]]
        L.append("")
    L.append("  # ================= 机场节点域名匹配规则 =================")
    for ap in active:
        L += ["  - tag: match_specific_domains_%s" % ap["name"],
              "    type: domain_set",
              "    args:",
              "      files:",
              "        - \"rules/%s\"" % os.path.basename(ap["domains"])]
        L.append("")
    L.append("  # ================= 机场专属处理链：独立缓存 → 机场私有 DNS（拿不到应答就返回主链走默认链路） =================")
    for ap in active:
        L += ["  - tag: handle_specific_%s" % ap["name"],
              "    type: sequence",
              "    args:"]
        if ap["ipv6"]:
            L += ["      # 该机场有 IPv6 节点（AIRPORTS 里带了 ipv6 标记）→ 不拒绝 AAAA(qtype 28)",
                  "      # （原来这里放的是 qtype 28 的 reject）"]
        else:
            L += ["      # 该机场没有 IPv6 节点 → 拒绝 AAAA(qtype 28)，客户端只拿 IPv4 节点",
                  "      - matches:",
                  "        - qtype 28",
                  "        exec: reject"]
        L += ["      - exec: $cache_%s" % ap["name"],
              "      - matches:",
              "        - has_resp",
              "        exec: accept",
              "      - exec: $forward_%s" % ap["name"],
              "      - matches:",
              "        - has_resp",
              "        exec: accept",
              "      # 机场私有 DNS 没答复 → 不 accept，返回主链由 config.yaml 的默认链路兜底"]
        L.append("")

# ---------- 机场分发链（config.yaml 的 main_sequence 第一步就 jump 到这里） ----------
L += ["  # ================= 机场分发链（config.yaml 的 main_sequence 第一步跳到这里） =================",
      "  - tag: airport_router",
      "    type: sequence",
      "    args:"]
if active:
    for ap in active:
        L += ["      - matches:",
              "          - qname $match_specific_domains_%s" % ap["name"],
              "        exec: jump handle_specific_%s" % ap["name"]]
else:
    L += ["      # 当前没有任何机场可用 → 这里必须是空操作（链首 has_resp 必为假），请求落回默认链路",
          "      - matches:",
          "        - has_resp",
          "        exec: accept"]

text = "\n".join(L) + "\n"

# ---------- 校验：可解析 + 必备 tag + 引用完整 + 规则文件非空 ----------
try:
    cfg = yaml.safe_load(text)
except Exception as e:
    print("INVALID|生成的 YAML 解析失败: %s" % e); raise SystemExit(0)
if not isinstance(cfg, dict) or not cfg.get("plugins"):
    print("INVALID|生成结果没有 plugins"); raise SystemExit(0)

defined = set()
for ap in active:
    defined.update({"forward_%s" % ap["name"], "cache_%s" % ap["name"],
                    "match_specific_domains_%s" % ap["name"], "handle_specific_%s" % ap["name"]})
defined.add("airport_router")

missing_tags = [t for t in ("airport_router",) if t not in defined]
if missing_tags:
    print("INVALID|缺少必备插件: %s" % ", ".join(missing_tags)); raise SystemExit(0)

missing = sorted(r for r in set(re.findall(r'\$([A-Za-z0-9_]+)', text)) if r not in defined)
if missing:
    print("INVALID|引用了未定义的插件: %s" % ", ".join(missing)); raise SystemExit(0)

for ap in active:
    for path in (ap["domains"], ap["dns"]):
        if not os.path.isfile(path) or os.path.getsize(path) == 0:
            print("INVALID|文件为空: %s" % path); raise SystemExit(0)

open(out_path, "w").write(text)
print("VALID|%d" % len(active))
PY
)

case "$GEN_RESULT" in
    VALID\|*) ACTIVE_COUNT="${GEN_RESULT#VALID|}" ; echo "  ✅ 生成并通过校验（参与分流的机场：${ACTIVE_COUNT} 个）" ;;
    *) echo "  ❌ ${GEN_RESULT#INVALID|}"; echo "  ❌ 已中止，mosdns 现有配置保持不变"; rm -rf "$TMP_DIR"; exit 1 ;;
esac


# ==============================
# 4. 真启动预检（临时容器）
# ==============================
echo "用临时容器预检新配置..."

PRE_DIR="$TMP_DIR/preflight"
rm -rf "$PRE_DIR"
mkdir -p "$PRE_DIR/rules" "$PRE_DIR/log"
cp -f "$TMP_DIR/airports_gen.yaml.new" "$PRE_DIR/airports_gen.yaml"
# 预检用的 config.yaml：以线上 config.yaml 为底，只把 include 指向新生成的文件
python3 - "$WORK_DIR/config.yaml" "$TMP_DIR/airports_gen.yaml.new" "$PRE_DIR/config.yaml" <<'PY'
import sys, re
src, gen, dst = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    base = open(src).read()
except Exception:
    base = "include:\n  - \"airports_gen.yaml\"\n"
open(dst, "w").write(base if "airports_gen.yaml" in base else 'include:\n  - "airports_gen.yaml"\n')
PY
cp -f "$RULES_DIR"/airport_domains_*.txt "$PRE_DIR/rules/" 2>/dev/null

MOSDNS_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null)
if [ -z "$MOSDNS_IMAGE" ]; then
    echo "  ⚠️ 拿不到 mosdns 镜像名，跳过预检（后面的健康检查仍会兜底）"
else
    PRE_OUT=$(timeout 8 docker run --rm -v "$PRE_DIR:/etc/mosdns" "$MOSDNS_IMAGE" 2>&1)
    PRE_CODE=$?
    if [ "$PRE_CODE" = "124" ]; then
        echo "  ✅ 预检通过（新配置能正常启动）"
    else
        echo "  ❌ 预检失败（exit=$PRE_CODE），新配置起不来："
        echo "$PRE_OUT" | tail -5 | sed 's/^/     /'
        echo "  ❌ 已中止，mosdns 现有配置保持不变"
        rm -rf "$TMP_DIR"
        exit 1
    fi
fi


# ==============================
# 5. 备份（只留最新一份）+ 替换 + 重启 + 健康检查（失败回滚）
# ==============================

NEW_GEN="$WORK_DIR/.airports_gen.yaml.new"
cp -f "$TMP_DIR/airports_gen.yaml.new" "$NEW_GEN"

same_file() {
    [ -f "$2" ] || return 1
    grep -v "更新时间" "$1" > "$TMP_DIR/cmp_a" 2>/dev/null
    grep -v "更新时间" "$2" > "$TMP_DIR/cmp_b" 2>/dev/null
    cmp -s "$TMP_DIR/cmp_a" "$TMP_DIR/cmp_b"
    return $?
}

CHANGED=0
same_file "$NEW_GEN" "$GEN_FILE" || CHANGED=1
[ "$RULES_CHANGED" = "1" ] && CHANGED=1

CONTAINER_RUNNING=0
if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    [ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)" = "running" ] && CONTAINER_RUNNING=1
fi

if [ "$CHANGED" = "0" ] && [ "$CONTAINER_RUNNING" = "1" ]; then
    echo "  ℹ️ 配置无变化，不重启容器"
    rm -f "$NEW_GEN"
    rm -rf "$TMP_DIR"
else
    TS=$(date "+%Y%m%d-%H%M%S")
    if [ -f "$GEN_FILE" ]; then
        cp -p "$GEN_FILE" "${GEN_FILE}.bak-${TS}"
        # 只保留最新一份备份，避免越积越多
        ls -1t "${GEN_FILE}".bak-* 2>/dev/null | tail -n +2 | while read -r old; do
            [ -n "$old" ] && rm -f "$old"
        done
    fi
    mv -f "$NEW_GEN" "$GEN_FILE"
    echo "  已备份原配置为 $(basename "${GEN_FILE}").bak-${TS}（旧的同名前缀备份已清理）"

    T0=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    echo "重启 Docker 容器 ${CONTAINER_NAME}..."
    docker restart "$CONTAINER_NAME" >/dev/null 2>&1
    RESTART_BASE=$(docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null)

    HEALTH=0
    n=1
    while [ "$n" -le 6 ]; do
        sleep 3
        ST=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)
        RC=$(docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null)
        if [ "$ST" = "running" ] && [ "$RC" = "$RESTART_BASE" ]; then
            if docker logs --since "$T0" "$CONTAINER_NAME" 2>&1 | grep -qiE 'FATAL|failed to init|can not find'; then
                HEALTH=0
            else
                HEALTH=1
                break
            fi
        fi
        n=$((n + 1))
    done

    if [ "$HEALTH" = "1" ]; then
        echo "  ✅ 健康检查通过（容器 running，重启计数未增长，日志无 FATAL）"
        rm -rf "$TMP_DIR"
    else
        echo "  ❌ 健康检查失败！回滚到上一版配置并重启..."
        if [ -f "${GEN_FILE}.bak-${TS}" ]; then
            cp -f "${GEN_FILE}.bak-${TS}" "$GEN_FILE"
        else
            echo "  ⚠️ 没有可用备份（首次生成？），保留当前文件不覆盖"
        fi
        docker restart "$CONTAINER_NAME" >/dev/null 2>&1
        sleep 5
        echo "  ---- 最近日志 ----"
        docker logs --tail 8 "$CONTAINER_NAME" 2>&1 | sed 's/^/     /'
        rm -rf "$TMP_DIR"
        echo "======================"
        echo "失败退出（配置已回滚）: $UPDATE_TIME"
        echo "======================"
        exit 1
    fi
fi

echo "======================"
echo "各机场处理结果："
echo "$SUMMARY_TEXT"
echo "TIME: $UPDATE_TIME"
echo "DONE"
echo "======================"