"""Standard-library ARR client. Errors never include response bodies or secrets."""
import argparse
import sys
import datetime
import tempfile
import ast
import os
from pathlib import Path
import json
import math
import time
import urllib.error
import urllib.parse
import urllib.request

NOT_FOUND = object()

def log(text):
    if text.startswith(('【已提交搜索】', '【已清理】')):
        print(text, flush=True)
    elif any(marker in text for marker in ('【错误】', '【执行失败】', '【未完成】')):
        print(text, file=sys.stderr, flush=True)


class ArrError(Exception):
    pass

def write_report(path, report):
    target = Path(path)
    fd, temporary = tempfile.mkstemp(prefix='.' + target.name + '.', dir=target.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(report, stream, indent=2, ensure_ascii=False, allow_nan=False)
            stream.write('\n')
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def cli(mode, argv=None):
    parser = argparse.ArgumentParser(description='ARR ' + mode + ': default read-only dry-run')
    parser.add_argument('--config', default=str(Path(__file__).with_name('config.json')))
    report_dir = Path(tempfile.gettempdir()) / ('arr-' + str(os.getuid()))
    report_dir.mkdir(mode=0o700, exist_ok=True)
    parser.add_argument('--report', default=str(report_dir / ('arr-' + mode + '-report.json')))
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--apply', action='store_true', help='Explicitly permit production writes')
    group.add_argument('--dry-run', action='store_true', help='Read-only (default)')
    parser.add_argument('--service', choices=['both', 'sonarr', 'radarr'], default='both')
    parser.add_argument('--extract-config', metavar='OLD_SCRIPT', help='Extract literal config only; no API calls; refuses overwrite')
    args = parser.parse_args(argv)
    if args.extract_config:
        if args.apply:
            parser.error('--apply cannot be combined with --extract-config')
        try:
            save_config(args.config, extract_config(args.extract_config))
            print('Private config created (0600); original source not executed.')
            return 0
        except (ArrError, OSError):
            print('Config extraction/write failed (existing destination is not overwritten).')
            return 1
    result = {'mode': mode, 'apply': args.apply, 'generated_at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'services': {}, 'errors': []}
    log('【开始】' + ('正式执行' if args.apply else '预览模式：只读取，不搜索、不移除') + '｜任务：' + ('搜索' if mode == 'search' else '清理（保留媒体文件）'))
    clients = {}
    try:
        config = load_config(args.config)
        for app in ('radarr', 'sonarr'):
            settings = config[app]
            if not settings.get('enabled', True) or args.service not in ('both', app):
                continue
            client = Client(settings['url'], settings['api_key'], timeout=config.get('timeout', 15))
            clients[app] = client
            log('【扫描】' + app.title() + '：读取标签、队列及媒体库，请稍候……')
            try:
                report = scan(client, app, mode, settings)
                log('【扫描完成】' + app.title() + '：库条目 ' + str(report['library_count']) + '，符合条件 ' + str(len(report['candidates'])) + '，错误 ' + str(len(report['errors'])))
                for candidate in report['candidates']:
                    label = candidate.get('title', 'ID ' + str(candidate['id']))
                    if mode == 'cleanup':
                        reason = '文件齐全且分数达标；将移除 ARR 条目，保留媒体文件'
                    else:
                        score = candidate.get('score')
                        reason = '缺失文件（沿用原规则，可能包含未播出集）' if score is None else '自定义格式分数 ' + str(score) + '，低于目标 ' + str(candidate.get('threshold'))
                    log('  【候选】' + label + '｜' + reason)
                result['services'][app] = report
            except ArrError as exc:
                result['services'][app] = {'app': app, 'mode': mode, 'candidates': [], 'succeeded': 0, 'errors': [{'error': str(exc)}], 'library_count': None}
        if args.apply and any(r['errors'] for r in result['services'].values()):
            result['errors'].append('Apply blocked for all services: incomplete scan')
        else:
            for app, report in result['services'].items():
                try:
                    execute(clients[app], report, apply=args.apply)
                except ArrError as exc:
                    report['errors'].append({'error': str(exc)})
                    log('【执行失败】' + app.title() + '：' + str(exc) + '；停止后续提交，不自动重试。')
                    break  # Do not continue writes after an uncertain outcome.
    except ArrError as exc:
        result['errors'].append(str(exc))
    for app, report in result['services'].items():
        report['http_calls'] = clients[app].calls
        report['candidate_count'] = len(report['candidates'])
        log('【汇总】' + app.title() + '：符合条件 ' + str(report['candidate_count']) + '，已核实执行 ' + str(report['succeeded']) + '，错误 ' + str(len(report['errors'])))
        for error in report['errors']:
            log('  【错误】' + str(error.get('error', '未知错误')))
    try:
        write_report(args.report, result)
    except (OSError, ValueError):
        log('【错误】无法保存 JSON 报告。')
        return 1
    if result['errors'] or any(r['errors'] for r in result['services'].values()):
        log('【未完成】存在扫描或执行错误；详见报告：' + str(args.report) + '。不会自动重试写操作。')
        return 1
    log('【结束】' + ('正式任务完成；已受理搜索不等于下载完成。' if args.apply else '预览完成，没有发起搜索或移除。') + ' 报告：' + str(args.report))
    return 0


def validate_config(config):
    if not isinstance(config, dict):
        raise ArrError('Config must be an object')
    timeout = config.get('timeout', 15)
    if type(timeout) not in (int, float) or not math.isfinite(timeout) or timeout <= 0:
        raise ArrError('Invalid timeout')
    for app in ('sonarr', 'radarr'):
        settings = config.get(app)
        if not isinstance(settings, dict) or type(settings.get('enabled', True)) is not bool:
            raise ArrError('Invalid service config')
        for field, default in [('target_score', 400)] + ([('target_score_ultrahd', 1080)] if app == 'radarr' else []):
            score = settings.get(field, default)
            if type(score) not in (int, float) or not math.isfinite(score):
                raise ArrError('阈值必须是有限数值：' + app + '.' + field)
        if not settings.get('enabled', True):
            continue
        url = settings.get('url')
        key = settings.get('api_key')
        if not isinstance(url, str) or not isinstance(key, str) or not key:
            raise ArrError('Missing service URL or API key')
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in ('http', 'https') or not parsed.netloc or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise ArrError('Invalid service URL')
    return config


def extract_config(source):
    try:
        tree = ast.parse(Path(source).read_text())
        values = {}
        wanted = {'SONARR_URL', 'SONARR_API_KEY', 'SONARR_ENABLE', 'RADARR_URL', 'RADARR_API_KEY', 'RADARR_ENABLE', 'REQUEST_TIMEOUT'}
        for node in tree.body:
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Name) and target.id in wanted:
                        values[target.id] = ast.literal_eval(node.value)
        config = {'timeout': values.get('REQUEST_TIMEOUT', 15)}
        for app in ('sonarr', 'radarr'):
            prefix = app.upper()
            config[app] = {'enabled': values.get(prefix + '_ENABLE', True), 'url': values.get(prefix + '_URL'), 'api_key': values.get(prefix + '_API_KEY')}
        return validate_config(config)
    except (OSError, SyntaxError, ValueError, TypeError):
        raise ArrError('Cannot extract literal config (source not executed)') from None


def save_config(path, config):
    validate_config(config)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(config, stream, indent=2)
        stream.write('\n')


def load_config(path):
    try:
        p = Path(path)
        if p.stat().st_mode & 0o077:
            raise ArrError('Private config must have mode 0600 (chmod 600)')
        return validate_config(json.loads(p.read_text()))
    except (OSError, ValueError, TypeError):
        raise ArrError('Cannot read valid private JSON config') from None


def require_list(data):
    if not isinstance(data, list) or any(not isinstance(x, dict) for x in data):
        raise ArrError('Invalid list response')
    return data


def queue_ids(queue, field):
    ids = set()
    for row in queue:
        value = row.get(field)
        if type(value) is not int or value <= 0:
            raise ArrError('Queue identity missing: ' + field)
        ids.add(value)
    return ids


def validate_item(item, file_status=False):
    if type(item.get('id')) is not int or item['id'] <= 0 or type(item.get('monitored')) is not bool:
        raise ArrError('Invalid item identity/monitoring status')
    if file_status and type(item.get('hasFile')) is not bool:
        raise ArrError('Unknown file presence')


def mapping(data, field):
    result = {}
    for item in require_list(data):
        if type(item.get('id')) is not int or not isinstance(item.get(field), str) or not item[field] or item['id'] in result:
            raise ArrError('Invalid ' + field + ' mapping')
        result[item['id']] = item[field]
    return result


def protected(item, tags):
    values = item.get('tags')
    if not isinstance(values, list):
        raise ArrError('Missing or invalid tags')
    labels = set()
    for tag in values:
        if isinstance(tag, dict):
            label = tag.get('label') or tags.get(tag.get('id'))
        else:
            label = tags.get(tag) if type(tag) is int else None
        if not isinstance(label, str) or not label:
            raise ArrError('Unknown tag; skipped')
        labels.add(label)
    return 'no-auto-unmonitor' in labels


def file_score(client, item, kind):
    nested = item.get(kind + 'File') or {}
    fid = item.get(kind + 'FileId') or (nested.get('id') if isinstance(nested, dict) else None)
    if type(fid) is not int or fid <= 0:
        raise ArrError('Missing file ID')
    data = client.request('GET', kind + 'file/' + str(fid))
    score = data.get('customFormatScore') if isinstance(data, dict) else None
    if type(score) not in (int, float) or not math.isfinite(score):
        raise ArrError('Missing or invalid custom format score')
    return score


def scan(client, app, mode, settings=None):
    settings = settings or {}
    report = {'app': app, 'mode': mode, 'candidates': [], 'succeeded': 0, 'errors': [], 'skipped': [], 'library_count': 0}
    tags = mapping(client.request('GET', 'tag'), 'label')
    if app == 'sonarr':
        return scan_sonarr(client, mode, tags, report, settings.get('target_score', 400))
    profiles = mapping(client.request('GET', 'qualityprofile'), 'name')
    queue = client.queue() if mode == 'search' else []
    downloading = queue_ids(queue, 'movieId')
    report['queue_count'] = len(queue) if mode == 'search' else None
    movies = require_list(client.request('GET', 'movie'))
    report['library_count'] = len(movies)
    for item in movies:
        try:
            validate_item(item, file_status=True)
            if not item.get('monitored') or not item.get('hasFile') or item['id'] in downloading or protected(item, tags):
                continue
            profile = profiles.get(item.get('qualityProfileId'))
            if not isinstance(profile, str) or not profile:
                raise ArrError('Unknown quality profile; skipped')
            threshold = settings.get('target_score_ultrahd', 1080) if 'ultra-hd' in profile.lower() else settings.get('target_score', 400)
            score = file_score(client, item, 'movie')
            if (score < threshold) if mode == 'search' else (score >= threshold):
                report['candidates'].append({'id': item['id'], 'title': item.get('title', '电影 ID ' + str(item['id'])), 'score': score, 'threshold': threshold})
        except ArrError as exc:
            report['errors'].append({'id': item.get('id'), 'error': str(exc)})
    return report


def scan_sonarr(client, mode, tags, report, threshold=400):
    queue = client.queue()
    downloading = queue_ids(queue, 'episodeId') if mode == 'search' else set()
    downloading_series = queue_ids(queue, 'seriesId') if mode == 'cleanup' else set()
    report['queue_count'] = len(queue)
    series = require_list(client.request('GET', 'series'))
    report['library_count'] = len(series)
    for item in series:
        try:
            validate_item(item)
            if not item.get('monitored') or protected(item, tags):
                continue
            if mode == 'cleanup' and item['id'] in downloading_series:
                continue
            episodes = require_list(client.request('GET', 'episode', {'seriesId': item['id']}))
            for ep in episodes:
                validate_item(ep, file_status=True)
            if mode == 'cleanup':
                monitored = [ep for ep in episodes if ep.get('monitored')]
                if not monitored or any(not ep.get('hasFile') for ep in monitored):
                    continue
                scores = [file_score(client, ep, 'episode') for ep in monitored]
                if all(score >= threshold for score in scores):
                    report['candidates'].append({'id': item['id'], 'title': item.get('title', '剧集 ID ' + str(item['id'])), 'monitored_episodes': len(monitored), 'minimum_score': min(scores)})
                continue
            for ep in episodes:
                if not ep.get('monitored') or ep['id'] in downloading:
                    continue
                try:
                    score = file_score(client, ep, 'episode') if ep.get('hasFile') else None
                    if score is None or score < threshold:
                        report['candidates'].append({'id': ep['id'], 'title': item.get('title', '剧集 ID ' + str(item['id'])) + ' S' + str(ep.get('seasonNumber', '?')).zfill(2) + 'E' + str(ep.get('episodeNumber', '?')).zfill(2), 'series_id': item['id'], 'score': score, 'threshold': threshold})
                except ArrError as exc:
                    report['errors'].append({'id': ep.get('id'), 'error': str(exc)})
        except ArrError as exc:
            report['errors'].append({'id': item.get('id'), 'error': str(exc)})
    return report


def execute(client, report, apply=False, sleep=time.sleep):
    report['apply'] = apply
    report['verified_commands'] = []
    report['attempted'] = 0
    if not apply:
        return report
    if report['errors']:
        raise ArrError('Apply blocked: incomplete scan')
    ids = [x['id'] for x in report['candidates']]
    if report['mode'] == 'cleanup':
        resource = 'series' if report['app'] == 'sonarr' else 'movie'
        exclusion = 'addImportListExclusion' if report['app'] == 'sonarr' else 'addImportExclusion'
        for identifier in ids:
            path = resource + '/' + str(identifier)
            log('【移除条目】' + report['app'].title() + ' ID ' + str(identifier) + '：保留媒体文件，不添加列表排除。')
            report['attempted'] += 1
            client.request('DELETE', path, query={'deleteFiles': 'false', exclusion: 'false'})
            if client.request('GET', path, allow_404=True) is not NOT_FOUND:
                raise ArrError('Delete readback was not HTTP 404; outcome unknown')
            report['succeeded'] += 1
            label = next((x.get('title', 'ID ' + str(identifier)) for x in report['candidates'] if x['id'] == identifier), 'ID ' + str(identifier))
            log('【已清理】' + report['app'].title() + '：' + label + '（保留媒体文件）')
        return report
    size = 5 if report['app'] == 'sonarr' else 1
    batches = [ids[i:i + size] for i in range(0, len(ids), size)]
    key = 'episodeIds' if report['app'] == 'sonarr' else 'movieIds'
    name = 'EpisodeSearch' if report['app'] == 'sonarr' else 'MoviesSearch'
    for index, batch in enumerate(batches):
        log('【提交搜索】' + report['app'].title() + ' 第 ' + str(index + 1) + '/' + str(len(batches)) + ' 批，共 ' + str(len(batch)) + ' 项，ID：' + ', '.join(map(str, batch)))
        report['attempted'] += len(batch)
        result = client.request('POST', 'command', body={'name': name, key: batch})
        cid = result.get('id') if isinstance(result, dict) else None
        if type(cid) is not int or cid <= 0:
            raise ArrError('POST command returned no valid ID; outcome unknown')
        command = client.request('GET', 'command/' + str(cid))
        if not isinstance(command, dict) or command.get('id') != cid or str(command.get('name', '')).lower() != name.lower() or command.get('status') not in ('queued', 'started', 'completed') or not isinstance(command.get('body'), dict) or command['body'].get(key) != batch:
            raise ArrError('Command readback failed validation; outcome unknown')
        report['verified_commands'].append({'id': cid, 'status': command['status']})
        report['succeeded'] += len(batch)
        labels = {x['id']: x.get('title', 'ID ' + str(x['id'])) for x in report['candidates']}
        log('【已提交搜索】' + report['app'].title() + '：' + '、'.join(labels[i] for i in batch))
        log('【已确认受理】命令 ID ' + str(cid) + '，状态：' + {'queued':'排队中','started':'执行中','completed':'已完成'}.get(command['status'], command['status']) + '；不代表已成功下载。')
        if report['app'] == 'sonarr' and index < len(batches) - 1:
            log('【等待】50 秒后提交下一批……')
            sleep(50)
    return report


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, url, api_key, timeout=15):
        self.base = url.rstrip('/') + '/api/v3/'
        self.api_key = api_key
        self.timeout = timeout
        self.opener = urllib.request.build_opener(NoRedirect())
        self.calls = []

    def queue(self):
        records = []
        page = 1
        total = None
        seen = set()
        while True:
            data = self.request('GET', 'queue', {'page': page, 'pageSize': 100, 'includeUnknownSeriesItems': 'false', 'includeUnknownMovieItems': 'false'})
            if not isinstance(data, dict) or type(data.get('totalRecords')) is not int or not isinstance(data.get('records'), list):
                raise ArrError('Invalid queue response')
            if total is None:
                total = data['totalRecords']
            if total < 0 or data['totalRecords'] != total:
                raise ArrError('Queue changed during pagination; retry later')
            batch = data['records']
            if any(not isinstance(r, dict) for r in batch):
                raise ArrError('Invalid queue record')
            signature = json.dumps(batch, sort_keys=True)
            if batch and signature in seen:
                raise ArrError('Repeated queue page')
            seen.add(signature)
            records.extend(batch)
            if len(records) == total:
                return records
            if not batch or len(records) > total:
                raise ArrError('Incomplete queue response')
            page += 1

    def request(self, method, path, query=None, body=None, allow_404=False):
        self.calls.append({'method': method, 'endpoint': path})
        url = self.base + path
        if query:
            url += '?' + urllib.parse.urlencode(query)
        req = urllib.request.Request(url, method=method, headers={'X-Api-Key': self.api_key, 'Content-Type': 'application/json'}, data=json.dumps(body).encode() if body is not None else None)
        try:
            with self.opener.open(req, timeout=self.timeout) as response:
                raw = response.read()
                if not 200 <= response.status < 300:
                    raise ArrError('Unexpected HTTP status')
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as exc:
            exc.close()
            if allow_404 and exc.code == 404:
                return NOT_FOUND
            raise ArrError(f'{method} {path.split("/")[0]} HTTP {exc.code}') from None
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            raise ArrError(f'{method} {path.split("/")[0]} transport/JSON failure') from None
