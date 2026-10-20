# fnOS / NAS 宿主脚本

## 文件与风险

- [zipdocker.sh](./zipdocker.sh)：将 `/vol2/@team/docker` 打包为 `.tar.zst`，输出到 `/vol2/@team/backup/docker`。只暂停名称包含 mysql 且原本运行中的容器，并在结束或异常时尝试恢复。其他容器继续运行，因此不保证 SQLite 等热数据的一致性。脚本包含旧备份清理逻辑，运行前务必审阅保留规则和输出路径。
- [MacvlanBridge.sh](./MacvlanBridge.sh)：创建并启用 `macvlan-shim.service`，建立宿主到指定 macvlan 容器的路由。网卡名、shim 地址和目标 IP 均与原环境绑定，必须先修改匹配本机；执行会立即改变网络并设置开机启用。
- [bbr.sh](./bbr.sh)：修改 `/etc/sysctl.conf` 的默认队列与 TCP 拥塞控制设置并应用，要求内核支持 BBR；不是只读检查。

## 使用前

在 NAS 宿主运行，按脚本需要准备 root / sudo、Docker、压缩与网络工具权限。先逐项检查内容及硬编码参数，不要整目录批量运行。

Docker 备份脚本需要 `docker`、`tar`、`zstd`、`flock`、`nice`、`ionice` 等工具。备份成功不等于恢复流程已验证，正式使用前应自行安排恢复演练。
