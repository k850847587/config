# 代理服务脚本

## 容器内入口

[docker-mihomo.sh](./docker-mihomo.sh) 是 Mihomo Docker 启动脚本，不是宿主升级脚本：

- 在容器 `eth0` 上检查或添加 `fe80::110/64`，等待 IPv6 地址就绪，最后执行 `/mihomo`。
- `--healthcheck` 分支检查地址状态，并通过 `fe80::110%eth0` 查询百度的 A 记录。
- 依赖容器内 `ip`、`timeout`、`nslookup`、`awk` 等命令；添加地址需要相应网络管理权限。
- 此脚本的 DNS 检查不等于节点代理连通性或所有业务正常。

示例入口路径取决于实际挂载；原环境使用 `/root/.config/mihomo/docker-mihomo.sh`。不要在 NAS 宿主直接运行此入口，以免修改宿主网络。

## 宿主维护脚本

- [update-mihomo-kernel-docker.sh](./update-mihomo-kernel-docker.sh)：获取 Mihomo 预发布内核、校验并按需替换；内容变化时会涉及容器停止与启动，包含回滚逻辑。核对发布分支、CPU 架构、`WORK_DIR`、`BIN_PATH`、`CONTAINER_NAME` 与代理地址后再使用。
- [restart-mihomo-docker.sh](./restart-mihomo-docker.sh)：重启 Mihomo 并检查稳定性；周日或设置 `FORCE_MODEL_UPDATE=1` 时还会检查 LightGBM 模型更新，因此不是始终仅做重启。
- [update-mosdns-rule.sh](./update-mosdns-rule.sh)：根据配置的机场订阅生成机场域名和私有 DNS 分发配置，依赖 mosdns 原有主配置；主配置仍需提供默认链路。生成变化可能触发替换、重启及回滚，运行前核对订阅占位值、路径和依赖安装逻辑。

维护脚本通常需要 Docker 访问权限及 `curl`、Python 3、`jq` 等工具，具体以各脚本依赖检查为准。不要为查看效果直接执行升级、重启或规则更新；本仓库不自动添加调度任务。
