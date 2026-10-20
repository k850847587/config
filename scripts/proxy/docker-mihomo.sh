#!/bin/sh
set -e
# 初始化
echo "init..."
fail() { echo "错误：$*" >&2; exit 1; }
address_status() {
  addresses=$(ip -6 addr show dev eth0) || fail '读取 eth0 IPv6 地址失败'
  printf '%s\n' "$addresses" | grep -F 'inet6 fe80::110/64 ' || true
}
if [ "${1:-}" = "--healthcheck" ]; then
  status=$(address_status)
  case "$status" in
    ''|*dadfailed*|*tentative*) fail 'fe80::110 地址不存在、冲突或尚未就绪' ;;
  esac
  answer=$(timeout 3 nslookup -type=A baidu.com fe80::110%eth0 2>/dev/null) || fail 'IPv6 DNS 查询失败或超时'
  printf '%s\n' "$answer" | awk '/^Name:/ { in_answer=1 } in_answer && /^Address:[[:space:]]+[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+[[:space:]]*$/ { n=split($2, octets, "[.]"); valid=(n==4); for (i=1; i<=n; i++) if (octets[i]>255) valid=0; if (valid) found=1 } END { exit !found }' || fail 'IPv6 DNS 未返回有效 A 记录'
  exit 0
fi
status=$(address_status)
if [ -z "$status" ]; then
   ip -6 addr add fe80::110/64 dev eth0 || fail '添加 fe80::110/64 失败'
   echo "添加fe80::110/64 成功!"
fi
attempt=0
while :; do
  status=$(address_status)
  case "$status" in *dadfailed*) fail 'fe80::110 地址重复检测失败，存在地址冲突' ;; esac
  if [ -n "$status" ]; then
    case "$status" in *tentative*) ;; *) break ;; esac
  fi
  [ "$attempt" -lt 50 ] || fail '等待 fe80::110 就绪超时，地址缺失或 DAD 未完成'
  sleep 0.2
  attempt=$((attempt + 1))
done
echo "识别fe80::110/64 成功!"
exec /mihomo