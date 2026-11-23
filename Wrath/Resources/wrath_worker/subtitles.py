"""Caption tracks that native FFmpeg can embed as MOV timed text."""
import html
import re
import urllib.parse

from .runtime import check_cancelled
from .urls import is_web_url

TEXT_EXTENSIONS = ('vtt', 'srt', 'ttml', 'dfxp')
TRACK_LIMIT = 4 * 1024 * 1024
TOO_LARGE = 'Subtitle track is too large.'


def _readable(fmt):
    return (isinstance(fmt, dict) and fmt.get('ext') in TEXT_EXTENSIONS
            and (isinstance(fmt.get('data'), str)
                 or (is_web_url(fmt.get('url')) and fmt.get('protocol', 'https') in ('http', 'https'))))


def subtitle_catalog(info):
    """Offer only actual caption tracks we can read without a subtitle decoder."""
    result = []
    for field, automatic in (('subtitles', False), ('automatic_captions', True)):
        for language, formats in (info.get(field) or {}).items():
            if language == 'live_chat' or not isinstance(formats, list):
                continue
            if automatic and language.endswith('-orig') and language[:-5] in info[field]:
                continue
            candidates = [f for f in formats if _readable(f)]
            if automatic and info.get('extractor_key') == 'Youtube':
                # Skip YouTube's machine translations of the automatic track.
                candidates = [f for f in candidates
                              if not urllib.parse.parse_qs(urllib.parse.urlparse(f.get('url', '')).query).get('tlang')]
            if not candidates:
                continue
            fmt = min(candidates, key=lambda f: TEXT_EXTENSIONS.index(f['ext']))
            result.append((dict(id=f'{"auto" if automatic else "manual"}:{language}',
                                language=str(language)[:100], name=str(fmt.get('name') or language)[:200],
                                automatic=automatic), fmt))
    return sorted(result, key=lambda item: (item[0]['automatic'],
                                           not item[0]['language'].startswith('en'), item[0]['name'].casefold()))


def _read_cues(content):
    timestamp = r'(?:\d+:)?\d{2}:\d{2}[.,]\d{3}'
    timing = re.compile(rf'^\s*({timestamp})\s*-->\s*({timestamp})(?:\s.*)?$')

    def seconds(value):
        parts = value.replace(',', '.').split(':')
        return sum(float(p) * factor for p, factor in zip(reversed(parts), (1, 60, 3600), strict=False))

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
                    raise ValueError(TOO_LARGE)
                cues.append(dict(start=start, end=end, text=text))
            break
    if not cues:
        raise ValueError('No usable subtitle cues.')
    return cues


def _flatten(cues):
    """MOV timed text cannot overlap. A sweep preserves simultaneous lines,
    including rolling automatic captions, without overlapping packet times."""
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
                raise ValueError(TOO_LARGE)
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


def parse_subtitle_cues(content, extension):
    """Plain selectable text, with overlapping WebVTT cues made nonoverlapping."""
    if extension in ('ttml', 'dfxp'):
        from yt_dlp.utils import dfxp2srt
        content = dfxp2srt(content.encode('utf-8'))
    return _flatten(_read_cues(content))


def _iso639_2(language):
    from yt_dlp.utils import ISO639Utils
    language = language.split('-')[0]
    if len(language) == 2:
        return ISO639Utils.short2long(language) or 'und'
    return language if len(language) == 3 else 'und'


def download_subtitle(info, options, ydl):
    catalog = subtitle_catalog(info)
    selected = options.get('subtitleTrack', 'automatic')
    if selected == 'automatic':
        choice = next(iter(catalog), None)
    else:
        choice = next((item for item in catalog if item[0]['id'] == selected), None)
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
            data = response.read(TRACK_LIMIT + 1)
        if len(data) > TRACK_LIMIT:
            raise ValueError(TOO_LARGE)
        content = data.decode('utf-8-sig')
    if len(content.encode('utf-8')) > TRACK_LIMIT:
        raise ValueError(TOO_LARGE)
    check_cancelled()
    return dict(language=_iso639_2(metadata['language']), name=metadata['name'],
                cues=parse_subtitle_cues(content, fmt['ext']))
