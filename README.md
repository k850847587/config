# NAS 配置与维护脚本

个人 NAS / 家庭实验室的脱敏配置与脚本，按用途分类保存。内容与特定网络、目录及内核分支有关，不是开箱即用的一键部署包。

## 目录

- [mihomo](./mihomo/README.md)：NAS、手机与电脑客户端配置。
- [singbox](./singbox/README.md)：sing-box reF1nd 分支配置及参考资料。
- [scripts](./scripts/README.md)：ARR、fnOS 与代理服务维护脚本。
- [substore](./substore/README.md)：Sub-Store 私有 DNS 策略及相关脚本。

## 使用前

- 替换订阅地址、API Key、控制密钥等占位值；不要公开自己的凭据。
- 核对网卡名、IP、路径、容器名及软件版本，尤其是硬编码的局域网参数。
- 先阅读目录说明与脚本内容；涉及删除条目、备份清理、系统网络和容器启停的脚本，不要直接照搬运行。
- 仓库不包含运行缓存与日志。静态语法正确不代表适用于你的运行环境。
