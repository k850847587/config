#!/bin/bash
set -Eeuo pipefail
umask 077
WORK_DIR="${WORK_DIR:-/vol2/@team/docker/proxy/mihomo}"
BIN_PATH="${BIN_PATH:-${WORK_DIR}/mihomo}"
CONTAINER_NAME="${CONTAINER_NAME:-mihomo}"
PROXY="${PROXY:-socks5h://192.168.11.110:1081}"
API_URL="https://api.github.com/repos/vernesong/mihomo/releases/tags/Prerelease-Alpha"
# API_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha"
TMP_DIR=''
ROLLBACK_NEEDED=false
MODIFIED=false
WAS_RUNNING=false
STABILITY_INTERVAL="${STABILITY_INTERVAL:-3}"
STABILITY_SAMPLES="${STABILITY_SAMPLES:-5}"
check_stable() {
    local expected=$1 baseline version health i
    baseline=$(docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME") || return 1
    for (( i=0; i<STABILITY_SAMPLES; i++ )); do
        sleep "$STABILITY_INTERVAL" || return 1
        [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME") == true ]] || return 1
        [[ $(docker inspect -f '{{.State.Restarting}}' "$CONTAINER_NAME") == false ]] || return 1
        [[ $(docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME") == "$baseline" ]] || return 1
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME") || return 1
        [[ $health == healthy || $health == none || $health == starting ]] || return 1
        version=$(docker exec "$CONTAINER_NAME" /mihomo -v) || return 1
        [[ $version == "$expected" ]] || return 1
    done
}
rollback() {
    local running
    echo '升级失败，恢复原内核及运行状态'
    running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME") || return 1
    if [[ $MODIFIED == true ]]; then
        if [[ $running == true ]]; then docker stop "$CONTAINER_NAME" >/dev/null || return 1; fi
        [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME") == false ]] || return 1
        cp -p -- "$BACKUP_PATH" "$BIN_PATH" || return 1
        [[ $("$BIN_PATH" -v) == "$old_version" ]] || return 1
    fi
    running=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME") || return 1
    if [[ $WAS_RUNNING == true ]]; then
        if [[ $running != true ]]; then docker start "$CONTAINER_NAME" >/dev/null || return 1; fi
        check_stable "$old_version" || return 1
    elif [[ $running == true ]]; then
        docker stop "$CONTAINER_NAME" >/dev/null || return 1
    fi
    echo '回滚完成，已恢复原运行状态（保留备份）'
}
finish() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    if [[ $ROLLBACK_NEEDED == true ]]; then
        (( rc != 0 )) || rc=1
        rollback || printf '错误：自动恢复失败，请人工处理；备份：%s\n' "$BACKUP_PATH" >&2
    fi
    [[ -z $TMP_DIR ]] || rm -rf -- "$TMP_DIR"
    printf '————————————执行完毕(%s)————————————\n' "$(date '+%Y-%m-%d %H:%M')"
    exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '————————————执行开始(%s)————————————\n' "$(date '+%Y-%m-%d %H:%M')"
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
DOWNLOAD_DIR=''
DOWNLOAD_ARCH=''
if (( $# > 0 )); then
    [[ $1 == --download-only && ( $# == 2 || $# == 3 ) ]] || fail '用法：脚本 [--download-only 已存在目录 [amd64-v3|arm64]]'
    DOWNLOAD_DIR=$2
    DOWNLOAD_ARCH=${3:-}
    [[ -d $DOWNLOAD_DIR ]] || fail '下载输出目录必须已存在'
fi
for tool in curl jq gzip sha256sum mktemp chmod rm date cp uname; do
    command -v "$tool" >/dev/null || fail "缺少依赖：$tool"
done
[[ $STABILITY_SAMPLES =~ ^[0-9]+$ ]] && (( STABILITY_SAMPLES >= 2 )) || fail '稳定检查次数至少为2'
machine=$(uname -m)
case "$machine" in
    x86_64|amd64) asset_arch=amd64-v3 ;;
    aarch64|arm64) asset_arch=arm64 ;;
    *) fail "不支持的CPU架构：$machine" ;;
esac
if [[ -n $DOWNLOAD_ARCH ]]; then
    case "$DOWNLOAD_ARCH" in amd64-v3|arm64) asset_arch=$DOWNLOAD_ARCH ;; *) fail '下载验证架构只支持amd64-v3或arm64' ;; esac
fi
if [[ -z $DOWNLOAD_DIR ]]; then
for tool in docker sleep; do command -v "$tool" >/dev/null || fail "缺少依赖：$tool"; done
[[ -f $BIN_PATH && ! -L $BIN_PATH ]] || fail '现有内核不存在或为符号链接'
docker inspect "$CONTAINER_NAME" >/dev/null
mounts=$(docker inspect -f '{{json .Mounts}}' "$CONTAINER_NAME")
sources=$(jq -er '[.[] | select(.Type == "bind") | .Source] | .[]' <<<"$mounts") || fail '无法读取bind挂载源'
while IFS= read -r source; do
    [[ -e $source ]] || fail "挂载源不存在，禁止升级：$source"
done <<<"$sources"
fi
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mihomo-update.XXXXXXXX")
fetch() {
    local url=$1 output=$2 limit=$3
    [[ $url == https://* ]] || fail '拒绝非HTTPS下载地址'
    local args=(-fSSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time "$limit" -H 'User-Agent: Mihomo-Updater-Script' -o "$output")
    local label='发布信息'
    [[ $url != https://github.com/* ]] || label='内核文件'
    echo "获取${label}：尝试 SOCKS5（$PROXY）"
    if curl "${args[@]}" --proxy "$PROXY" "$url" 2>"$TMP_DIR/curl-error"; then
        echo "获取${label}成功：使用 SOCKS5"
        return 0
    fi
    if [[ $url == https://github.com/* ]]; then
        echo "SOCKS5失败，获取${label}：直连 ghproxy.net"
        if curl "${args[@]}" --proxy '' --noproxy '*' "https://ghproxy.net/$url" 2>"$TMP_DIR/curl-error"; then
            echo "获取${label}成功：使用 ghproxy.net（无SOCKS5）"
            return 0
        fi
        echo 'ghproxy.net失败，尝试GitHub原地址直连'
    else
        echo 'SOCKS5失败，GitHub API直连（ghproxy.net不支持该API）'
    fi
    curl "${args[@]}" --proxy '' --noproxy '*' "$url" 2>"$TMP_DIR/curl-error" || fail 'HTTPS请求失败（所有可用通道均失败）'
    echo "获取${label}成功：使用GitHub原地址直连"
}
fetch "$API_URL" "$TMP_DIR/api.json" 30
asset=$(jq -er --arg pattern "^mihomo-linux-${asset_arch}-alpha(?:-[A-Za-z0-9._-]+)?\\.gz$" '[.assets[] | select(.name | test($pattern))] | if length == 1 then .[0] else error("资产缺失或不唯一") end' "$TMP_DIR/api.json") || fail "未找到唯一${asset_arch}-alpha资产"
filename=$(jq -er '.name' <<<"$asset")
printf 'CPU：%s；资产：%s\n' "$machine" "$filename"
url=$(jq -er '.browser_download_url' <<<"$asset")
digest=$(jq -r '.digest // empty' <<<"$asset")
fetch "$url" "$TMP_DIR/asset.gz" 300
if [[ -n $digest ]]; then
    [[ $digest =~ ^sha256:[a-fA-F0-9]{64}$ ]] || fail 'API资产digest格式不支持'
    actual=$(sha256sum "$TMP_DIR/asset.gz"); actual=${actual%% *}
    [[ ${actual,,} == ${digest#sha256:} ]] || fail 'API资产SHA256不匹配'
    echo 'API资产SHA256校验通过'
else
    echo 'API未提供digest：仅做后续格式/可执行性校验，不代表checksum认证（下载模式不执行内核）'
fi
gzip -t "$TMP_DIR/asset.gz" || fail 'gzip格式校验失败'
if [[ -n $DOWNLOAD_DIR ]]; then
    [[ ! -e $DOWNLOAD_DIR/$filename && ! -L $DOWNLOAD_DIR/$filename ]] || fail '下载目标已存在，拒绝覆盖'
    ( set -o noclobber; cp -n -- "$TMP_DIR/asset.gz" "$DOWNLOAD_DIR/$filename" )
    echo "仅下载验证完成：${DOWNLOAD_DIR}/${filename}（未执行内核、未验证配置、未调用Docker）"
    exit 0
fi
gzip -dc "$TMP_DIR/asset.gz" >"$TMP_DIR/new"
chmod 755 "$TMP_DIR/new"
new_version=$("$TMP_DIR/new" -v) || fail '新内核无法执行'
[[ $new_version == *Mihomo* ]] || fail '新内核版本输出无效'
image=$(docker inspect -f '{{.Image}}' "$CONTAINER_NAME")
# 复用真实容器所有挂载但强制只读；仅运行-t，不运行服务、不写入生产配置。
if ! docker run --rm --read-only --network none --cap-drop ALL --security-opt no-new-privileges \
    --volumes-from "${CONTAINER_NAME}:ro" \
    --mount "type=bind,src=${TMP_DIR}/new,dst=/candidate,readonly" \
    --entrypoint /candidate "$image" -t -d /root/.config/mihomo >"$TMP_DIR/config-check.log" 2>&1; then
    fail '新内核现有配置只读校验失败（可能需要预先补全本地规则/数据）'
fi
old_hash=$(sha256sum "$BIN_PATH"); old_hash=${old_hash%% *}
new_hash=$(sha256sum "$TMP_DIR/new"); new_hash=${new_hash%% *}
if [[ $old_hash == "$new_hash" ]]; then
    echo '内核hash未变化，跳过替换和重启'
    exit 0
fi
old_version=$("$BIN_PATH" -v) || fail '旧内核无法读取版本'
printf '版本：%s -> %s\n' "${old_version%%$'\n'*}" "${new_version%%$'\n'*}"
BACKUP_PATH="${WORK_DIR}/mihomo.bak"
[[ ! -L $BACKUP_PATH ]] || fail '备份路径不能为符号链接'
cp -p -- "$BIN_PATH" "$BACKUP_PATH"
echo "已保留备份：$BACKUP_PATH"
WAS_RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")
ROLLBACK_NEEDED=true
if [[ $WAS_RUNNING == true ]]; then docker stop "$CONTAINER_NAME" >/dev/null; fi
[[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME") == false ]] || fail '容器未停止，禁止覆盖'
# 不能mv/rename；停容器后原位覆盖，保留单文件bind所指向的inode。
MODIFIED=true
cp -- "$TMP_DIR/new" "$BIN_PATH"
chmod 755 "$BIN_PATH"
[[ $("$BIN_PATH" -v) == "$new_version" ]] || fail '替换后内核版本不符合预期'
if [[ $WAS_RUNNING == true ]]; then
    docker start "$CONTAINER_NAME" >/dev/null
    check_stable "$new_version" || fail '升级后版本/运行稳定性验证失败'
    echo '升级完成，版本一致且运行稳定'
else
    [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME") == false ]] || fail '容器原停止状态改变'
    echo '升级完成，保留原停止状态（未启动容器，未做容器exec验证）'
fi
ROLLBACK_NEEDED=false
