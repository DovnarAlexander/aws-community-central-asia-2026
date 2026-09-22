#!/usr/bin/env python3
"""Pull slides/talk.md apart into one record per slide.

    scripts/pptx/extract.py deck.json

Layout, title, prose, bullets, tables, code and the cast step it plays, plus the
presenter notes -- the deck is written as Slidev markdown with HTML in it, and
PowerPoint wants none of that, so the structure is read out once here and the
builder never touches markdown.
"""
import json, os, re, sys, pathlib, html

# `--scenes` prints the diagram groupings for the layer renderer, so the task
# script does not carry a second copy of them that can fall out of step with the
# builder's.
if '--scenes' in sys.argv:
    sys.path.insert(0, str(pathlib.Path(__file__).parent))
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        'ot', pathlib.Path(__file__).parent / 'onto-template.py')
    ot = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ot)
    seen = set()
    for name, groups in ot.SCENES.values():
        if name in seen:
            continue
        seen.add(name)
        print(f'{name}|{json.dumps(groups)}')
    raise SystemExit(0)

src = pathlib.Path('slides/talk.md').read_text()
# frontmatter of the deck itself
body = src.split('\n---\n', 1)[1] if src.startswith('---') else src
chunks = re.split(r'\n---\n', body)

slides, cur = [], None
for ch in chunks:
    # A chunk that is only frontmatter keys opens the next slide.
    if re.match(r'^\s*(layout|class|transition|variant|level|mdc|clicks|hideInToc)\s*:', ch.strip()):
        if cur: slides.append(cur)
        cur = {'layout': 'default', 'class': '', 'raw': ''}
        for k in ('layout', 'class', 'variant'):
            m = re.search(rf'^{k}:\s*(.+)$', ch, re.M)
            if m: cur[k] = m.group(1).strip()
        continue
    if cur is None:
        cur = {'layout': 'cover', 'class': '', 'raw': ''}
    cur['raw'] += ch
if cur: slides.append(cur)

def clean(t, keep_blanks=False):
    t = re.sub(r'<!--.*?-->', '', t, flags=re.S)
    t = re.sub(r'<[^>]+>', ' ', t)
    t = html.unescape(t)
    t = re.sub(r'\*\*(.+?)\*\*', r'\1', t)
    t = re.sub(r'`([^`]+)`', r'\1', t)
    t = re.sub(r'[ \t]+', ' ', t)
    # Stripping <strong> and <code> leaves a space in front of the punctuation
    # that followed them: "10 seconds ." and "every single time ,". The lookahead
    # keeps "then ./demo" intact.
    t = re.sub(r'\s+([.,;:!?])(?=\s|$)', r'\1', t)
    if keep_blanks:
        # Notes are a laid-out page: the blank lines between their sections are
        # what makes them readable in the pane, so they survive here.
        return '\n'.join(l.strip() for l in t.splitlines())
    return '\n'.join(l.strip() for l in t.splitlines() if l.strip())

# Cut lengths, so a note can say how long its recording runs without anybody
# keeping the number in step by hand. Re-recording the show moves every one of
# them; retyping them into talk.md is how a note ends up lying.
LENGTHS, STEPTITLES, SECONDS = {}, {}, {}
try:
    with open('slides/public/casts/full.cuts.json') as fh:
        man = json.load(fh)
    hold = json.load(open('scripts/pptx/hold.json'))
    for c in man['cuts']:
        secs = (c['to'] if c['to'] is not None else man['duration']) - c['from']
        # A step the deck holds longer than it ran is that much longer on the
        # slide, and the note has to say the number the speaker will watch.
        # A step cut into beats is `1.2.3` and the factor is written against
        # `1.2`: holding is a property of the step, not of the slide.
        secs *= hold.get(c['step'], hold.get(c.get('parent'), 1))
        LENGTHS[c['step']] = f'{int(secs // 60)}:{int(secs % 60):02d}'
        STEPTITLES[c['step']] = c['title']
        SECONDS[c['step']] = secs
except (OSError, KeyError, ValueError):
    pass

# Words a minute. A technical talk delivered carefully, not a podcast: this is
# the dial to turn if the rehearsed clock comes out consistently fast or slow.
WPM = float(os.environ.get('TALK_WPM', 140))


# A line attributed to somebody is on the screen -- the recording is already
# saying it, and the speaker is not reading it out. A bare line is the
# speaker's own. That convention is what makes a recording slide's timing
# checkable at all: counting the screen's dialogue as speech says a two-minute
# segment needs three and a half minutes of talking, which is only true if you
# are reading the film aloud.
# Names carry commas and roles ("Timur, backend:") and some of them are
# lowercase on purpose ("kubelet, the executioner:"), so neither an initial
# capital nor a single word can be required.
NAMED = re.compile(r'^\s*(?:\d+\s+)?[A-Za-z][A-Za-z\'\u2019, ]{1,28}:\s*["\u201c]')


def spoken_seconds(notes):
    """Seconds of speech in a note.

    Square brackets are stage directions -- what appears, where to point, what
    the room is doing -- and nobody says them out loud. A leading number is the
    click the line belongs to. Neither is counted, and neither is a line the
    screen is already speaking.
    """
    # Brackets first and across the whole note: a stage direction that wraps
    # onto a second line is still a stage direction, and stripping them line by
    # line left half of every long one counted as speech.
    text = re.sub(r'\[[^\]]*\]', ' ', notes, flags=re.S)
    words = 0
    for line in text.splitlines():
        if NAMED.match(line):
            continue
        words += len(re.sub(r'^\s*\d+\s*', ' ', line).split())
    return words / WPM * 60



out = []
for s in slides:
    raw = s['raw']
    notes = '\n'.join(clean(m, keep_blanks=True) for m in re.findall(r'<!--(.*?)-->', raw, re.S))
    notes = re.sub(r'\n{3,}', '\n\n', notes).strip()
    code  = re.findall(r'```(\w*)\s*(?:\{[^}]*\})?\n(.*?)```', raw, re.S)
    step  = re.search(r'step="([\d.]+)"', raw)
    nocode = re.sub(r'```.*?```', '', raw, flags=re.S)
    title = re.search(r'^#\s+(.+)$', nocode, re.M)
    sub   = re.search(r'^##\s+(.+)$', nocode, re.M)
    prose = clean(re.sub(r'^#{1,6}\s+.*$', '', nocode, flags=re.M))
    items = re.findall(r'<li[^>]*>(.*?)</li>', raw, re.S)
    # Markdown tables otherwise reach the slide as literal "| --- | --- |" rows.
    tables, tbl = [], []
    for line in nocode.splitlines():
        if line.strip().startswith('|'):
            cells = [clean(c) for c in line.strip().strip('|').split('|')]
            if all(set(c) <= set('-: ') for c in cells): continue   # the rule row
            tbl.append(cells)
        elif tbl:
            tables.append(tbl); tbl = []
    if tbl: tables.append(tbl)
    prose = '\n'.join(l for l in prose.splitlines() if not l.strip().startswith('|'))
    out.append({
        'layout': s['layout'], 'class': s['class'],
        'title': clean(title.group(1)) if title else '',
        'subtitle': clean(sub.group(1)) if sub else '',
        'prose': prose, 'bullets': [clean(i) for i in items],
        'tables': tables,
        'code': [{'lang': l or 'text', 'text': c.rstrip()} for l, c in code],
        'step': step.group(1) if step else None,
        'steptitle': STEPTITLES.get(step.group(1), '') if step else '',
        'notes': (notes.replace('{len}', LENGTHS.get(step.group(1), '?:??'))
                  if step else notes),
        # How long this slide is on screen. A recording is however long it
        # runs; anything else is however long its notes take to say, which is
        # the only honest estimate available and the one the speaker controls.
        'seconds': (SECONDS.get(step.group(1), 0) if step
                    else spoken_seconds(notes)),
        # How long the note takes to SAY, always. For a slide that is a
        # recording this is the number that matters and the only one nothing
        # else was checking: the film runs for as long as it runs whatever is
        # written underneath it, so a note too long for its own slide is a
        # speaker talking over the next one. It goes in the note header, and
        # the summary below says which slides do not fit.
        'speech': spoken_seconds(notes),
    })
json.dump(out, open(sys.argv[1], 'w'), indent=1, ensure_ascii=False)
print(f"  {len(out)} slides, {sum(1 for s in out if s['step'])} of them a recording")
for i, s in enumerate(out, 1):
    tag = f"cast {s['step']}" if s['step'] else (s['title'][:46] or s['layout'])
    print(f"   {i:>2}  {s['layout']:<8} {tag}")

# ── does the talking fit the film ────────────────────────────────────────────
# A recording plays for as long as it plays. Everything else on the slide is
# paced by the speaker, so it cannot be too long for itself; a recording can,
# and when it is, the speaker is still on this slide's words while the next
# slide's film is running. FIT is how much of a film may be talking: the rest is
# the room reading the screen, which is what the screen is for.
FIT = float(os.environ.get('TALK_FIT', 0.9))
tight = []
for i, s in enumerate(out, 1):
    if not s['step'] or not s['seconds']:
        continue
    if s['speech'] > s['seconds'] * FIT:
        tight.append((i, s['step'], s['speech'], s['seconds']))
if tight:
    print(f"\n  \033[1;31m!\033[0m {len(tight)} recordings have more to say than "
          f"they have time to say it in:", file=sys.stderr)
    for i, step, said, runs in tight:
        over = said - runs * FIT
        print(f"    slide {i:>2}  {step:<7} film {runs:5.0f}s  "
              f"notes {said:5.0f}s  {over:+.0f}s over", file=sys.stderr)
    print(f"    Cut words, or move a beat in scripts/pptx/beats.json so the "
          f"film has longer.", file=sys.stderr)
