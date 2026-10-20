# Mihomo 配置

## 文件

- [config.yaml](./config.yaml)：NAS Mihomo 配置模板。
- [config-phone.yaml](./config-phone.yaml)：手机配置模板。
- [mihomo.yaml](./mihomo.yaml)：电脑 / Clash Verge 配置模板。

## 使用说明

1. 替换全部订阅地址与控制密钥占位值，核对本地 IP、端口、DNS 与 TUN 设置。
2. 根据实际内核检查配置兼容性；分支扩展不保证上游原版支持。
3. 手机和电脑模板对应的 Sub-Store 私有 DNS 处理方法见 [Sub-Store 说明](../substore/README.md)，不要把原始模板与脚本生成结果混淆。
4. 应用前使用实际运行的 Mihomo 内核进行配置检查，例如 `mihomo -t -d <配置目录>`。

Docker 启动入口及维护脚本见 [scripts/proxy](../scripts/proxy/README.md)。本目录不包含内核二进制、真实私人订阅或完整 Compose 部署。
