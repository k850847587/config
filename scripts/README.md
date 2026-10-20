# NAS 维护脚本

- [arr](./arr/README.md)：Sonarr / Radarr 搜索与达标条目清理。
- [fnos](./fnos/README.md)：Docker 目录备份、macvlan 宿主互通与 BBR 设置。
- [proxy](./proxy/README.md)：Mihomo Docker 启动、内核更新、重启与 mosdns 规则更新。

## 运行边界

脚本面向既有 NAS 环境；宿主维护脚本需要相应系统权限、依赖与 Docker 访问权限。不要把所有脚本放进容器内直接执行，特别注意 `proxy/docker-mihomo.sh` 是容器内入口，其他代理维护脚本主要在宿主运行。

发布副本不包含 `bak/`、`log/`、运行缓存或真实 API 密钥；本仓库不自动安装定时任务。

若需要控制台和文件同时留存日志，可在确认路径存在后采用：

```bash
bash -o pipefail -c 'bash /实际路径/脚本.sh 2>&1 | tee -a /实际日志目录/脚本.log'
```

此处是日志用法示例，不是通用于所有文件的执行命令。Shell 解释器、Python 入口与危险操作范围以各目录说明和脚本为准。
