"""Bundled extraction only. Swift owns transfers; libavformat owns remuxing."""
import json
import os
import sys
import urllib.parse
import urllib.request
import urllib.error
import hashlib
import math
import ssl
import re
import html

import certifi
import yt_dlp

try:
    import wrath_native
except ImportError:  # Allows host-side integration tests.
    wrath_native = None

if wrath_native:
    from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
    from yt_dlp.extractor.youtube.jsc.provider import register_provider, register_preference

    @register_provider
    class WrathJCP(EJSBaseJCP):
        JS_RUNTIME_NAME = 'JavaScriptCore'

        def is_available(self):
            return self._available

        def _run_js_runtime(self, stdin):
            check_cancelled()
            return wrath_native.evaluate(stdin)

    @register_preference(WrathJCP)
    def prefer_wrath(provider, requests):
        return 1000


def check_cancelled():
    if wrath_native and wrath_native.cancelled():
        raise RuntimeError('Cancelled')


class QuietLogger:
    def debug(self, message):
        check_cancelled()

    def warning(self, message):
        check_cancelled()

    def error(self, message):
        check_cancelled()


class InspectionYoutubeDL(yt_dlp.YoutubeDL):
    def list_formats(self, info_dict):
        # The app reads the structured -F catalog returned by extract_info.
        # Avoid rendering its terminal table into the iOS console as well.
        check_cancelled()

    def list_subtitles(self, video_id, subtitles, name='subtitles'):
        check_cancelled()


def selector(kind, height, video_codec='automatic', audio_codec='automatic', exact_height=False):
    cap = (f'[height={height}]' if exact_height else f'[height<=?{height}]') if height else ''
    video_patterns = {'h264': '^(avc1|h264)', 'hevc': '^(hev1|hvc1|hevc|h265)', 'av1': '^(av01|av1)', 'vp9': '^(vp09|vp9)'}
    audio_patterns = {'aac': '^(mp4a|aac)', 'opus': '^opus'}
    vf = f'[vcodec~="{video_patterns[video_codec]}"]' if video_codec in video_patterns else ''
    af = f'[acodec~="{audio_patterns[audio_codec]}"]' if audio_codec in audio_patterns else ''
    if kind == 'audio':
        return f'ba{af}[protocol^=http]/ba{af}[protocol^=m3u8]/b{af}[protocol^=http]/b{af}[protocol^=m3u8]'
    direct = '[protocol^=http]'
    return (f'bv{cap}{vf}{direct}+ba{af}{direct}/'
            f'b{cap}{vf}{af}{direct}/b{cap}{vf}{af}[protocol^=m3u8]')


SPONSOR_CATEGORIES = ('sponsor', 'selfpromo', 'interaction', 'intro', 'outro', 'preview', 'music_offtopic', 'filler')


def parse_sponsor_segments(records, video_id, categories, duration):
    result = []
    seen = set()
    for record in records:
        if not isinstance(record, dict) or record.get('videoID') != video_id or not isinstance(record.get('segments'), list):
            continue
        for segment in record.get('segments', []):
            if not isinstance(segment, dict):
                continue
            category = segment.get('category')
            if category not in categories or segment.get('actionType', 'skip') != 'skip':
                continue
            try:
                start, end = (float(x) for x in segment['segment'])
                reported_duration = float(segment.get('videoDuration') or 0)
            except (TypeError, ValueError, KeyError):
                continue
            if not math.isfinite(start) or not math.isfinite(end) or not math.isfinite(reported_duration) or not 0 <= start < end:
                continue
            if duration:
                if reported_duration and abs(reported_duration - duration) > max(2, duration * .01):
                    continue
                end = min(end, duration)
            key = (start, end, category)
            if start < end and key not in seen:
                result.append(dict(start=start, end=end, category=category)); seen.add(key)
    return sorted(result, key=lambda x: (x['start'], x['end']))[:500]


def sponsor_segments(info, options):
    if options.get('sponsorMode', 'off') == 'off' or info.get('extractor_key') != 'Youtube':
        return []
    categories = sorted(set(options.get('sponsorCategories', ['sponsor'])).intersection(SPONSOR_CATEGORIES))
    if not categories:
        raise ValueError('Choose at least one SponsorBlock category, or turn SponsorBlock off.')
    video_id = info['id']
    prefix = hashlib.sha256(video_id.encode()).hexdigest()[:4]
    query = urllib.parse.urlencode({'categories': json.dumps(categories), 'actionTypes': '["skip"]'})
    request = urllib.request.Request(f'https://sponsor.ajay.app/api/skipSegments/{prefix}?{query}', headers={'User-Agent': 'Wrath/1.2.0'})
    check_cancelled()
    try:
        with urllib.request.urlopen(request, timeout=12, context=ssl.create_default_context(cafile=certifi.where())) as response:
            data = response.read(2 * 1024 * 1024 + 1)
        if len(data) > 2 * 1024 * 1024:
            raise ValueError('SponsorBlock response was too large.')
        records = json.loads(data)
        if not isinstance(records, list):
            raise ValueError('Invalid SponsorBlock response.')
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return []
        raise ValueError('SponsorBlock is unavailable. Retry or turn SponsorBlock off.') from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise ValueError('SponsorBlock is unavailable. Retry or turn SponsorBlock off.') from error
    check_cancelled()
    return parse_sponsor_segments(records, video_id, categories, info.get('duration'))


def thumbnail_url(info):
    candidates = [info.get('thumbnail')]
    candidates.extend(item.get('url') for item in reversed(info.get('thumbnails') or []) if isinstance(item, dict))
    for url in candidates:
        if not isinstance(url, str) or any(character.isspace() for character in url):
            continue
        try:
            parsed = urllib.parse.urlparse(url)
            if parsed.scheme in ('https', 'http') and parsed.hostname:
                return url
        except ValueError:
            continue
    return None


def subtitle_catalog(info):
    """Offer only actual caption tracks we can read without a subtitle decoder."""
    result = []
    extensions = ('vtt', 'srt', 'ttml', 'dfxp')
    for field, automatic in (('subtitles', False), ('automatic_captions', True)):
        for language, formats in (info.get(field) or {}).items():
            if language == 'live_chat' or not isinstance(formats, list):
                continue
            if automatic and language.endswith('-orig') and language[:-5] in info[field]:
                continue
            candidates = [f for f in formats if isinstance(f, dict) and f.get('ext') in extensions
                          and (isinstance(f.get('data'), str) or
                               (thumbnail_url({'thumbnail': f.get('url')}) and
                                f.get('protocol', 'https') in ('http', 'https')))]
            if automatic and info.get('extractor_key') == 'Youtube':
                candidates = [f for f in candidates if not urllib.parse.parse_qs(urllib.parse.urlparse(f.get('url', '')).query).get('tlang')]
            if not candidates:
                continue
            fmt = min(candidates, key=lambda f: extensions.index(f['ext']))
            result.append((dict(id=f'{"auto" if automatic else "manual"}:{language}',
                                language=str(language)[:100], name=str(fmt.get('name') or language)[:200],
                                automatic=automatic), fmt))
    return sorted(result, key=lambda item: (item[0]['automatic'],
                                           not item[0]['language'].startswith('en'), item[0]['name'].casefold()))


def parse_subtitle_cues(content, extension):
    """Plain selectable text, with overlapping WebVTT cues made nonoverlapping."""
    if extension in ('ttml', 'dfxp'):
        from yt_dlp.utils import dfxp2srt
        content = dfxp2srt(content.encode('utf-8'))
    timestamp = r'(?:\d+:)?\d{2}:\d{2}[.,]\d{3}'
    timing = re.compile(rf'^\s*({timestamp})\s*-->\s*({timestamp})(?:\s.*)?$')

    def seconds(value):
        parts = value.replace(',', '.').split(':')
        return sum(float(p) * factor for p, factor in zip(reversed(parts), (1, 60, 3600)))

    cues = []
    for block in re.split(r'\n[ \t]*\n', content.replace('\r\n', '\n').replace('\r', '\n')):
        lines = block.strip().split('\n')
        if not lines or lines[0].startswith(('NOTE', 'STYLE', 'REGION')):
            continue
        for index, line in enumerate(lines[:3]):
            match = timing.match(line)
            if not match:
                continue
            start, end = map(seconds, match.groups())
            text = html.unescape(re.sub(r'<[^>]*>', '', '\n'.join(lines[index + 1:]))).replace('\x00', '').strip()
            # Remove SRT positioning/style override codes; retain Unicode and line breaks.
            text = re.sub(r'\{\\[^}]*\}', '', text)
            if 0 <= start < end <= 1e9 and text:
                if len(text.encode('utf-8')) > 20000 or len(cues) >= 20000:
                    raise ValueError('Subtitle track is too large.')
                cues.append(dict(start=start, end=end, text=text))
            break
    if not cues:
        raise ValueError('No usable subtitle cues.')
    # MOV timed text cannot overlap. A sweep preserves simultaneous lines,
    # including rolling automatic captions, without overlapping packet times.
    events = {}
    for index, cue in enumerate(cues):
        events.setdefault(cue['start'], []).append((index, True))
        events.setdefault(cue['end'], []).append((index, False))
    active, result, previous, total_bytes = set(), [], None, 0
    for position in sorted(events):
        check_cancelled()
        if previous is not None and active and position > previous:
            text = '\n'.join(dict.fromkeys(cues[i]['text'] for i in sorted(active)))
            size = len(text.encode('utf-8'))
            total_bytes += size
            if size > 60000 or total_bytes > 8 * 1024 * 1024:
                raise ValueError('Subtitle track is too large.')
            if result and result[-1]['end'] == previous and result[-1]['text'] == text:
                result[-1]['end'] = position
            else:
                result.append(dict(start=previous, end=position, text=text))
        for index, adding in events[position]:
            if adding:
                active.add(index)
            else:
                active.discard(index)
        if len(active) > 32:
            raise ValueError('Too many overlapping subtitle cues.')
        previous = position
    return result


def download_subtitle(info, options, ydl):
    catalog = subtitle_catalog(info)
    selected = options.get('subtitleTrack', 'automatic')
    choice = next((item for item in catalog if item[0]['id'] == selected), None) if selected != 'automatic' else next(iter(catalog), None)
    if choice is None:
        raise ValueError('Selected subtitle track is unavailable.')
    metadata, fmt = choice
    content = fmt.get('data')
    if content is None:
        from yt_dlp.networking import Request
        headers = dict(info.get('http_headers') or {})
        headers.update(fmt.get('http_headers') or {})
        check_cancelled()
        with ydl.urlopen(Request(fmt['url'], headers=headers)) as response:
            data = response.read(4 * 1024 * 1024 + 1)
        if len(data) > 4 * 1024 * 1024:
            raise ValueError('Subtitle track is too large.')
        content = data.decode('utf-8-sig')
    if len(content.encode('utf-8')) > 4 * 1024 * 1024:
        raise ValueError('Subtitle track is too large.')
    check_cancelled()
    from yt_dlp.utils import ISO639Utils
    language = metadata['language'].split('-')[0]
    language = (ISO639Utils.short2long(language) if len(language) == 2 else language if len(language) == 3 else None) or 'und'
    return dict(language=language, name=metadata['name'],
                cues=parse_subtitle_cues(content, fmt['ext']))


def make_plan(info, kind, ydl=None):
    if info.get('_type') in ('playlist', 'multi_video') or info.get('entries') is not None:
        raise ValueError('Paste a link to one video. Playlist downloads are not supported yet.')
    if info.get('is_live'):
        raise ValueError('Live streams are not supported. Try again after the stream has ended.')
    formats = info.get('requested_formats') or [info]
    tracks = []
    for fmt in formats:
        url = fmt.get('url', '')
        if urllib.parse.urlparse(url).scheme not in ('https', 'http'):
            raise ValueError('This source did not provide a downloadable HTTP stream.')
        protocol = fmt.get('protocol') or 'https'
        if protocol not in ('https', 'http', 'm3u8', 'm3u8_native'):
            raise ValueError('This stream format is not supported yet.')
        headers = {str(k): str(v) for k, v in (fmt.get('http_headers') or info.get('http_headers') or {}).items()
                   if '\r' not in str(k) + str(v) and '\n' not in str(k) + str(v)}
        tracks.append(dict(url=url, headers=headers,
                           role='audio' if fmt.get('vcodec') == 'none' else 'video',
                           streaming=protocol.startswith('m3u8'),
                           bytes=fmt.get('filesize') or fmt.get('filesize_approx'),
                           chunkSize=(fmt.get('downloader_options') or {}).get('http_chunk_size')))
        if ydl is not None and info.get('extractor_key') == 'TikTok' and protocol in ('http', 'https'):
            # URLSession needs the same cookies as yt-dlp's request handler.
            # Preserve scope instead of forwarding an unscoped Cookie header.
            cookies = [dict(name=c.name, value=c.value, domain=c.domain, path=c.path or '/',
                            secure=c.secure, expires=c.expires, hostOnly=not c.domain_specified)
                       for c in ydl.cookiejar.get_cookies_for_url(url)]
            if cookies:
                tracks[-1]['cookies'] = cookies
    if not tracks or len(tracks) > 2:
        raise ValueError('No compatible media tracks were found.')
    audio_codec = next((f.get('acodec', '') for f in formats if f.get('acodec') not in (None, 'none')), '')
    video_codec = next((f.get('vcodec', '') for f in formats if f.get('vcodec') not in (None, 'none')), '')
    if kind == 'audio':
        ext = 'm4a' if audio_codec.startswith(('mp4a', 'aac', 'alac')) else ('opus' if 'opus' in audio_codec else ('mp3' if 'mp3' in audio_codec else 'ogg'))
    else:
        compatible_video = video_codec.startswith(('avc', 'h264', 'hev', 'hvc', 'hevc', 'av01')) or (not video_codec and info.get('ext') == 'mp4')
        ext = 'mp4' if compatible_video and (not audio_codec or audio_codec.startswith(('mp4a', 'aac', 'alac'))) else 'mkv'
    height = max((f.get('height') or 0 for f in formats), default=0)
    return dict(title=info.get('title') or info.get('id') or 'Download',
                author=info.get('uploader') or info.get('channel') or '',
                source=info.get('extractor_key') or 'Web', duration=info.get('duration'),
                thumbnail=thumbnail_url(info), tracks=tracks, fileExtension=ext,
                quality=(f'{height}p' if height else 'Video') if kind == 'video' else 'Original audio')


def estimated_track_bytes(fmt, duration, audio_only=False):
    def positive(value):
        return isinstance(value, (int, float)) and math.isfinite(value) and 0 < value < 2**63

    # Audio extracted from a combined stream must not include the video bytes.
    extracting_audio = audio_only and fmt.get('vcodec') != 'none'
    if not extracting_audio:
        for field in ('filesize', 'filesize_approx'):
            if positive(fmt.get(field)):
                return int(fmt[field])
    bitrate = fmt.get('abr') if extracting_audio else fmt.get('tbr')
    if not positive(bitrate) and not extracting_audio:
        rates = [fmt.get(key) for key in ('vbr', 'abr') if positive(fmt.get(key))]
        bitrate = sum(rates) if rates else None
    if positive(duration) and positive(bitrate):
        size = duration * bitrate * 1000 / 8
        if positive(size):
            return int(size)
    return None


def codec_availability(info, ydl=None):
    if info.get('_type') in ('playlist', 'multi_video') or info.get('entries') is not None:
        raise ValueError('Paste a link to one video. Playlist downloads are not supported yet.')
    if info.get('is_live'):
        raise ValueError('Live streams are not supported. Try again after the stream has ended.')
    formats = [fmt for fmt in (info.get('formats') or [info])
               if urllib.parse.urlparse(fmt.get('url', '')).scheme in ('https', 'http')
               and fmt.get('protocol', 'https') in ('https', 'http', 'm3u8', 'm3u8_native')
               and not fmt.get('has_drm')]
    choices = []
    video_patterns = {'h264': ('avc1', 'h264'), 'hevc': ('hev1', 'hvc1', 'hevc', 'h265'),
                      'av1': ('av01', 'av1'), 'vp9': ('vp09', 'vp9')}
    audio_patterns = {'aac': ('mp4a', 'aac'), 'opus': ('opus',)}

    def codec_matches(fmt, field, codec, patterns):
        value = str(fmt.get(field) or '').lower()
        # yt-dlp uses 'none' for an absent track and None for an unknown codec
        # (common for direct media URLs). Unknown must still allow Automatic.
        return value != 'none' if codec == 'automatic' else value.startswith(patterns[codec])

    def http(fmt):
        return str(fmt.get('protocol') or 'https').startswith('http')

    def hls(fmt):
        return str(fmt.get('protocol') or '').startswith('m3u8')

    def at_height(fmt, height):
        return not height or fmt.get('height') == height

    def has_video(fmt):
        return fmt.get('vcodec') != 'none'

    def has_audio(fmt):
        return fmt.get('acodec') != 'none'

    video_candidates = ('automatic', *[c for c in video_patterns
                                       if any(codec_matches(f, 'vcodec', c, video_patterns) for f in formats)])
    audio_candidates = ('automatic', *[c for c in audio_patterns
                                       if any(codec_matches(f, 'acodec', c, audio_patterns) for f in formats)])
    has_any_audio = any(has_audio(f) for f in formats)

    # Match the downloader's sorting once per media kind. Reading estimates
    # requires no HEAD requests, media probes, or repeated selector evaluation.
    owned_sorter = ydl is None
    sorter = ydl or yt_dlp.YoutubeDL({'quiet': True, 'logger': QuietLogger()}, auto_init=False)
    previous_sort = sorter.params.get('format_sort')
    try:
        ordered = {}
        for kind in ('video', 'audio'):
            sorter.params['format_sort'] = ['res', 'vcodec:h264', 'acodec:aac'] if kind == 'video' else []
            rows = [dict(f) for f in formats]
            sorter.sort_formats(dict(formats=rows, _format_sort_fields=info.get('_format_sort_fields')))
            ordered[kind] = rows
    finally:
        sorter.params['format_sort'] = previous_sort
        if owned_sorter:
            sorter.close()

    def best(kind, predicate):
        return next((f for f in reversed(ordered[kind]) if predicate(f)), None)

    def choice(kind, height, video, audio, tracks):
        sizes = [estimated_track_bytes(f, info.get('duration'), audio_only=kind == 'audio') for f in tracks]
        size = sum(sizes) if sizes and all(s is not None for s in sizes) else None
        return dict(kind=kind, quality=height, videoCodec=video, audioCodec=audio,
                    estimatedBytes=size if size is not None and 0 < size < 2**63 else None)

    # -F already gives the complete format catalog. Determine supported choices
    # from its codec, resolution, and protocol columns instead of running the
    # format selector repeatedly for every possible combination.
    available_heights = sorted({int(f['height']) for f in formats if has_video(f)
                               and isinstance(f.get('height'), (int, float))
                               and math.isfinite(f['height']) and 0 < f['height'] <= 65536
                               and int(f['height']) == f['height']})
    for height in (0, *available_heights):
        check_cancelled()
        for video in video_candidates:
            for audio in audio_candidates:
                video_track = best('video', lambda f: has_video(f) and not has_audio(f) and at_height(f, height) and http(f)
                                   and codec_matches(f, 'vcodec', video, video_patterns))
                audio_track = best('video', lambda f: has_audio(f) and not has_video(f) and http(f)
                                   and codec_matches(f, 'acodec', audio, audio_patterns))
                if video_track is not None and audio_track is not None:
                    tracks = [video_track, audio_track]
                else:
                    tracks = []
                    for protocol in (http, hls):
                        progressive = best('video', lambda f: has_video(f) and (has_audio(f) or not has_any_audio)
                                           and at_height(f, height) and protocol(f)
                                           and codec_matches(f, 'vcodec', video, video_patterns)
                                           and (codec_matches(f, 'acodec', audio, audio_patterns)
                                                or (not has_any_audio and audio == 'automatic')))
                        if progressive is not None:
                            tracks = [progressive]
                            break
                if tracks:
                    choices.append(choice('video', height, video, audio, tracks))

    for audio in audio_candidates:
        for only_audio, protocol in ((True, http), (True, hls), (False, http), (False, hls)):
            track = best('audio', lambda f: has_audio(f) and (not has_video(f) if only_audio else has_video(f))
                         and protocol(f) and codec_matches(f, 'acodec', audio, audio_patterns))
            if track is not None:
                choices.append(choice('audio', 0, 'automatic', audio, [track]))
                break

    heights = [f.get('height') for f in formats if has_video(f) and isinstance(f.get('height'), (int, float))]
    return dict(choices=choices, exactQualities=True, thumbnailAvailable=thumbnail_url(info) is not None,
                thumbnail=thumbnail_url(info),
                subtitles=[metadata for metadata, _ in subtitle_catalog(info)],
                title=str(info.get('title') or info.get('id') or '')[:300],
                author=str(info.get('uploader') or info.get('channel') or '')[:200],
                duration=info.get('duration'), formatCount=len(formats),
                maxHeight=int(max(heights)) if heights else None)


# TikTok rejects some of yt-dlp's randomly selected Chrome versions.
# Keep inspection and media planning on the same verified browser identity.
TIKTOK_USER_AGENT = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                     'AppleWebKit/537.36 (KHTML, like Gecko) '
                     'Chrome/143.0.0.0 Safari/537.36')


def is_tiktok_url(url):
    if not isinstance(url, str):
        return False
    try:
        host = urllib.parse.urlparse(url).hostname or ''
    except ValueError:
        return False
    return any(host == domain or host.endswith('.' + domain) for domain in ('tiktok.com', 'tiktokv.com'))


def extract(request):
    data = {}
    try:
        data = json.loads(request)
        options = data.get('options') or {}
        inspecting = data.get('operation') == 'inspect'
        check_cancelled()
        ydl_options = dict(format='best' if inspecting else selector(data['kind'], int(data['quality']), options.get('videoCodec', 'automatic'), options.get('audioCodec', 'automatic'), exact_height=bool(data.get('exactQuality'))),
                       noplaylist=True, quiet=True, no_warnings=True,
                       logger=QuietLogger(), socket_timeout=20, retries=2,
                       extractor_retries=2, cachedir=data['cache'],
                       format_sort=['res', 'vcodec:h264', 'acodec:aac'] if data['kind'] == 'video' else [],
                       ca_certs=certifi.where(), skip_download=True,
                       remote_components=[], js_runtimes={},
                       # Original captions are in the same extraction result as -F.
                       # Avoid generating translations of uploaded YouTube captions.
                       extractor_args={'youtube': {'skip': ['translated_subs']}},
                       listformats=inspecting, simulate='list_only' if inspecting else False)
        if is_tiktok_url(data.get('url')):
            ydl_options['http_headers'] = {'User-Agent': TIKTOK_USER_AGENT}
        with (InspectionYoutubeDL if inspecting else yt_dlp.YoutubeDL)(ydl_options) as ydl:
            info = ydl.extract_info(data['url'], download=False)
            check_cancelled()
            if inspecting:
                return json.dumps({'availability': codec_availability(info, ydl)})
            plan = make_plan(info, data['kind'], ydl)
            if options.get('embedSubtitles') and data['kind'] == 'video':
                try:
                    plan['subtitle'] = download_subtitle(info, options, ydl)
                except Exception:
                    check_cancelled()
                    plan['subtitleWarning'] = 'Saved without subtitles: the selected track could not be downloaded or read.'
        check_cancelled()
        plan['sponsorSegments'] = sponsor_segments(info, options)
        return json.dumps({'plan': plan})
    except Exception as error:
        message = str(error).removeprefix('ERROR: ')
        if is_tiktok_url(data.get('url')) and any(reason in message for reason in (
                'Unexpected response from webpage request', 'Unable to extract challenge data',
                'Unable to extract universal data for rehydration')):
            message = ('TikTok returned a verification page instead of video details. '
                       'Retry the link, or open it in TikTok or Safari to check that it is available.')
        if 'Requested format is not available' in message and any((data.get('options') or {}).get(key, 'automatic') != 'automatic' for key in ('videoCodec', 'audioCodec')):
            message = 'The requested codec is not available at this quality. Choose Automatic, another codec, or a different quality.'
        return json.dumps({'error': message[:1200] or 'Unable to resolve this link.'})
