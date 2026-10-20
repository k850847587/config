# ARR 搜索与清理

## 文件

- [arr_upgrade_search.py](./arr_upgrade_search.py)：提交 Sonarr / Radarr 的缺失或低分资源搜索。
- [arr_unmonitor_full.py](./arr_unmonitor_full.py)：清理符合达标条件的库条目；虽然文件名带 unmonitor，实际操作并非仅取消监控。
- [arr_common.py](./arr_common.py)：两个入口共用的规则与 API 实现，需一起保存。
- [config.json](./config.json)：服务地址、评分阈值及 API Key 占位配置。

## 使用

需要 Python 3 和可访问的 Sonarr / Radarr API。先填写本地 `config.json`，核对服务地址与评分阈值，再查看参数：

```bash
python3 arr_upgrade_search.py --help
python3 arr_unmonitor_full.py --help
```

两个入口默认 dry-run；显式传入 `--apply` 才会提交写操作。首次使用应先预览，不直接添加 `--apply`。

## 注意

- 搜索请求被受理，不等于资源已成功下载。
- 清理会从 ARR 库移除符合条件的条目，保留媒体文件；不是单纯取消监控。
- 清理和搜索共用配置阈值，修改前核对电影、剧集及超高清的适用条件。
- 不要将真实 API Key 提交到公开仓库。
