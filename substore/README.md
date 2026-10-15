# Sub-Store 私有 DNS 策略脚本

对应配置：
- 手机：[`../mihomo/config-phone.yaml`](../mihomo/config-phone.yaml)
- 电脑 / Clash Verge：[`../mihomo/mihomo.yaml`](../mihomo/mihomo.yaml)

## 使用方法

1. 两份 YAML 是脱敏模板，先替换全部 `REPLACE_WITH_*_SUBSCRIPTION` 订阅地址及 `CHANGE_ME_CONTROLLER_SECRET`。
2. 在 Sub-Store 创建/导入本地配置文件，模式为配置文件（mihomoConfig）。
3. 添加「脚本操作」，模式选脚本，将 `private-dns-policy.js` 内容粘入。
4. 参数 `psnFile` 填写需要私有 DNS 的原始配置文件名，例如 `光速云-RAW.yaml,crush-raw.yaml`。原始文件必须同时包含 `dns.proxy-server-nameserver` 与 `proxies[].server`，仅节点列表不足以提取私有 DNS。
5. 下载 Sub-Store 生成结果导入客户端，而不是直接导入未处理的模板。

脚本只注入 `dns.proxy-server-nameserver-policy`，不改原配置的其他设置。按文件独立保存 last-good 数据，订阅读取失败、HTML/空内容或数据不完整时沿用历史；无历史则跳过该机场。缓存由 Sub-Store 数据卷持久保存，不能代替客户端的节点订阅缓存。

为避免公共后缀误判，使用完整节点域名精确匹配；相同节点域名出现冲突 DNS 时不随意选取其中一个。脚本使用 Sub-Store 环境提供的 API，不能作为独立 Node.js 脚本直接运行。

首次运行必须至少成功读取一次，才能建立对应机场的历史缓存。复制配置到不同文件名时缓存会独立建立。

## Clash Verge 注意事项

关闭 DNS 覆写，避免客户端覆盖脚本生成的私有 DNS 策略。实际 TUN 开关、代理端口等以 Clash Verge 的应用设置及最终运行配置为准。

仓库不包含私人订阅地址、控制密钥或运行缓存。发布副本保留源配置的注释、锚点、排版和规则顺序。
