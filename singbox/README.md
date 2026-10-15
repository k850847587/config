# sing-box reF1nd 分支配置与特性

本目录的 [`config.json`](./config.json) 面向 **sing-box reF1nd 分支**。该分支在上游 sing-box 的基础上扩展了机场订阅、策略组等功能，**不应直接视为官方原版内核的通用配置**。

使用前请根据所用内核版本核对配置格式，并替换配置中的订阅地址等占位内容。

## 内核下载与文档

- [内核下载（enpioodada/sing-box-core Releases）](https://github.com/enpioodada/sing-box-core/releases?utm_source=chatgpt.com)
- [中文配置文档（由 @DustinWin 提供）](https://sing-boxr.dustinwin.cc.cd/zh/configuration/)
- [与上游 testing 分支的代码差异](https://github.com/SagerNet/sing-box/compare/testing...reF1nd:sing-box:reF1nd-testing)

> 下载内核时请核对平台、架构和分支版本。下方链接涉及不同开发分支，具体支持情况以实际使用版本的文档与更新记录为准。

## 订阅与策略组

- **机场订阅支持**：通过 provider 管理机场订阅。  
  [配置说明](https://sing-boxr.dustinwin.cc.cd/zh/configuration/provider/)
- **在选择策略组中使用订阅**：将订阅节点接入 selector 策略组。  
  [配置说明](https://sing-boxr.dustinwin.cc.cd/zh/configuration/outbound/selector/)
- **负载均衡策略组**：loadbalance 策略组的配置与用法。  
  [配置说明](https://sing-boxr.dustinwin.cc.cd/zh/configuration/outbound/loadbalance/)
- **Fallback 策略组**：URLTest 的 fallback 扩展说明。  
  [配置说明（reF1nd-testing-next）](https://github.com/reF1nd/sing-box/tree/reF1nd-testing-next#urltest-fallback-支持)

## 其他扩展功能

- [DNS 并发：DNS server group](https://sing-boxr.dustinwin.cc.cd/zh/configuration/dns/server/group/)
- [Snell 出站](https://sing-boxr.dustinwin.cc.cd/zh/configuration/outbound/snell/)

### 统一延迟

补充配置项，可在顶层 `experimental` 中设置：

```json
{
  "experimental": {
    "urltest_unified_delay": true
  }
}
```

已有 `experimental` 时，将 `urltest_unified_delay` 合并到其中，不要重复创建同名顶层字段。此项为补充整理，是否支持请以所用内核版本为准。

## 特性更新记录

以下为整理的 Telegram 频道特性更新链接。配置格式与功能可能随版本变化，使用时请结合对应记录查看。

- [17](https://t.me/sing_box_reF1nd/17) · [47](https://t.me/sing_box_reF1nd/47) · [94](https://t.me/sing_box_reF1nd/94) · [199](https://t.me/sing_box_reF1nd/199) · [230](https://t.me/sing_box_reF1nd/230)
- [276](https://t.me/sing_box_reF1nd/276) · [306](https://t.me/sing_box_reF1nd/306) · [395](https://t.me/sing_box_reF1nd/395) · [539](https://t.me/sing_box_reF1nd/539) · [636](https://t.me/sing_box_reF1nd/636)
- [668](https://t.me/sing_box_reF1nd/668) · [940](https://t.me/sing_box_reF1nd/940) · [1036](https://t.me/sing_box_reF1nd/1036) · [1084](https://t.me/sing_box_reF1nd/1084) · [1910](https://t.me/sing_box_reF1nd/1910)
- [1947](https://t.me/sing_box_reF1nd/1947) · [2000](https://t.me/sing_box_reF1nd/2000) · [2172](https://t.me/sing_box_reF1nd/2172) · [2644](https://t.me/sing_box_reF1nd/2644) · [3016](https://t.me/sing_box_reF1nd/3016)
- [3078](https://t.me/sing_box_reF1nd/3078) · [3109](https://t.me/sing_box_reF1nd/3109) · [3140](https://t.me/sing_box_reF1nd/3140) · [3171](https://t.me/sing_box_reF1nd/3171) · [3636](https://t.me/sing_box_reF1nd/3636)
- [3851](https://t.me/sing_box_reF1nd/3851) · [3939](https://t.me/sing_box_reF1nd/3939) · [4059](https://t.me/sing_box_reF1nd/4059) · [4179](https://t.me/sing_box_reF1nd/4179)

## 致谢

感谢 sing-box 上游项目、reF1nd 分支维护者、中文文档贡献者 @DustinWin，以及相关构建与社区维护者。
