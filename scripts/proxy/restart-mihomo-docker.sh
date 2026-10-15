#!/bin/bash
set -Eeuo pipefail
CONTAINER_NAME="${CONTAINER_NAME:-mihomo}"
STABILITY_INTERVAL="${STABILITY_INTERVAL:-3}"
STABILITY_SAMPLES="${STABILITY_SAMPLES:-5}"
MODEL_TMP=''
MODEL_CHANGED=false
MODEL_WAS_RUNNING=false
MODEL_PATH=''
MODEL_BACKUP=''
finish() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    if [[ $MODEL_CHANGED == true && $rc != 0 ]]; then
        echo '错误：模型更新后启动验证失败，尝试回滚旧模型。' >&2
        docker stop "$CONTAINER_NAME" >/dev/null && cp -p -- "$MODEL_BACKUP" "$MODEL_PATH"
        if [[ $? != 0 ]]; then
            echo "错误：模型回滚失败，请检查 $MODEL_BACKUP" >&2
        elif [[ $MODEL_WAS_RUNNING == true ]]; then
            docker start "$CONTAINER_NAME" >/dev/null || echo '错误：回滚后容器启动失败' >&2
        fi
    fi
    [[ -z $MODEL_TMP ]] || rm -rf -- "$MODEL_TMP"
    printf '————————————执行完毕(%s)————————————\n' "$(date '+%Y-%m-%d %H:%M')"
    exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '————————————执行开始(%s)————————————\n' "$(date '+%Y-%m-%d %H:%M')"
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
WORK_DIR="${WORK_DIR:-/vol2/@team/docker/proxy/mihomo}"
for tool in docker jq sleep date; do command -v "$tool" >/dev/null || fail "缺少依赖：$tool"; done
[[ $STABILITY_SAMPLES =~ ^[0-9]+$ ]] && (( STABILITY_SAMPLES >= 2 )) || fail '稳定检查次数至少为2'
docker inspect "$CONTAINER_NAME" >/dev/null
mounts=$(docker inspect -f '{{json .Mounts}}' "$CONTAINER_NAME")
sources=$(jq -er '[.[] | select(.Type == "bind") | .Source] | .[]' <<<"$mounts") || fail '无法读取bind挂载源'
while IFS= read -r source; do
    [[ -e $source ]] || fail "挂载源不存在，禁止启停：$source"
done <<<"$sources"
# 周日的每日重启先检查模型；其他日子仍只执行原重启流程。
# FORCE_MODEL_UPDATE=1 可手动要求更新；不会修改 mihomo 自带的自动更新配置。
if [[ $(date +%u) == 7 || ${FORCE_MODEL_UPDATE:-0} == 1 ]]; then
    for tool in curl python3 mktemp sha256sum cp; do command -v "$tool" >/dev/null || fail "缺少依赖：$tool"; done
    MODEL_PATH="$WORK_DIR/Model.bin"
    [[ -f $MODEL_PATH && ! -L $MODEL_PATH ]] || fail '现有Model.bin不存在或为符号链接'
    MODEL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mihomo-model.XXXXXXXX")
    MODEL_URL="https://ghproxy.net/https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model.bin"
    MODEL_API="https://api.github.com/repos/vernesong/mihomo/releases/tags/LightGBM-Model"
    MODEL_PROXY="${PROXY:-socks5h://192.168.11.110:1081}"
    model_fetch() {
        local url=$1 output=$2
        local args=(-fSsL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 180 -o "$output")
        echo '模型更新：尝试SOCKS5'
        if curl "${args[@]}" --proxy "$MODEL_PROXY" "$url" 2>"$MODEL_TMP/curl-error"; then
            echo '模型更新：使用SOCKS5成功'
        else
            echo '模型更新：SOCKS5失败，尝试直连'
            curl "${args[@]}" --proxy '' --noproxy '*' "$url" 2>"$MODEL_TMP/curl-error" || fail '模型下载/发布信息获取失败，保留旧模型'
        fi
    }
    model_fetch "$MODEL_API" "$MODEL_TMP/api.json"
    model_fetch "$MODEL_URL" "$MODEL_TMP/Model.bin"
    # 检查发布摘要、大小及LightGBM文本模型头，拒绝HTML等错误页面。
    python3 - "$MODEL_TMP/api.json" "$MODEL_TMP/Model.bin" <<'PYMODEL'
import sys,json,hashlib
from pathlib import Path
try:
    assets=[a for a in json.loads(Path(sys.argv[1]).read_text())['assets'] if a.get('name')=='Model.bin']
    assert len(assets)==1
    a=assets[0];raw=Path(sys.argv[2]).read_bytes()
    assert raw.startswith(b'tree\n') and b'version=' in raw[:300] and b'num_class=' in raw[:300] and b'Tree=0' in raw
    assert len(raw)==a['size']
    assert a.get('digest')=='sha256:'+hashlib.sha256(raw).hexdigest()
except Exception:
    print('错误：模型格式/大小/SHA256校验失败，保留旧模型',file=sys.stderr)
    sys.exit(1)
PYMODEL
    old_hash=$(sha256sum "$MODEL_PATH");old_hash=${old_hash%% *}
    new_hash=$(sha256sum "$MODEL_TMP/Model.bin");new_hash=${new_hash%% *}
    if [[ $old_hash == "$new_hash" ]]; then
        echo '模型无变化，保留现有文件；继续每日重启。'
    else
        MODEL_BACKUP="$WORK_DIR/Model.bin.bak-$(date +%Y%m%d-%H%M%S)-$$"
        cp -p -- "$MODEL_PATH" "$MODEL_BACKUP"
        MODEL_WAS_RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME")
        # 标记先于stop，信号或部分失败也能进入恢复流程。
        MODEL_CHANGED=true
        if [[ $MODEL_WAS_RUNNING == true ]]; then docker stop "$CONTAINER_NAME" >/dev/null; fi
        [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME") == false ]] || fail '容器未停止，拒绝覆盖模型'
        cp -- "$MODEL_TMP/Model.bin" "$MODEL_PATH"
        [[ $(sha256sum "$MODEL_PATH") == "$new_hash  $MODEL_PATH" ]] || fail '模型写入校验失败'
        echo '模型更新完成，旧模型已备份；准备启动并验证。'
    fi
fi
if [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME") == true ]]; then
    docker restart "$CONTAINER_NAME" >/dev/null
    echo '已请求重启'
else
    docker start "$CONTAINER_NAME" >/dev/null
    echo '已请求启动'
fi
baseline=$(docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME")
for (( i=0; i<STABILITY_SAMPLES; i++ )); do
    sleep "$STABILITY_INTERVAL"
    [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME") == true ]] || fail '容器未运行'
    [[ $(docker inspect -f '{{.State.Restarting}}' "$CONTAINER_NAME") == false ]] || fail '容器正在反复重启'
    [[ $(docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME") == "$baseline" ]] || fail '容器重启计数变化'
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME")
    [[ $health == healthy || $health == none || $health == starting ]] || fail '容器健康状态未通过'
    version=$(docker exec "$CONTAINER_NAME" /mihomo -v) || fail '容器内核版本检查失败'
    [[ $version == *Mihomo* ]] || fail '容器内核版本输出无效'
done
printf '运行稳定：%s\n' "${version%%$'\n'*}"

MODEL_CHANGED=false
