#!/usr/bin/env python3
"""Pull slides/talk.md apart into one record per slide.

    scripts/pptx/extract.py deck.json

Layout, title, prose, bullets, tables, code and the cast step it plays, plus the
presenter notes -- the deck is written as Slidev markdown with HTML in it, and
PowerPoint wants none of that, so the structure is read out once here and the
builder never touches markdown.
"""
import json, re, sys, pathlib, html

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

def clean(t):
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
    return '\n'.join(l.strip() for l in t.splitlines() if l.strip())

out = []
for s in slides:
    raw = s['raw']
    notes = '\n'.join(clean(m) for m in re.findall(r'<!--(.*?)-->', raw, re.S))
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
        'notes': notes,
    })
json.dump(out, open(sys.argv[1], 'w'), indent=1, ensure_ascii=False)
print(f"  {len(out)} slides, {sum(1 for s in out if s['step'])} of them a recording")
for i, s in enumerate(out, 1):
    tag = f"cast {s['step']}" if s['step'] else (s['title'][:46] or s['layout'])
    print(f"   {i:>2}  {s['layout']:<8} {tag}")
