#!/usr/bin/env python3
"""Lay the talk out on the conference template.

    scripts/pptx/onto-template.py <workdir> <template.pptx> <out.pptx>

The organisers' deck is the base package: its masters, layouts, theme, grid,
logo and footer come through untouched, and every slide this writes is a clone
of one of theirs pointing at the same layout. Nothing is redrawn to look like
the template, so the typography really is theirs.

Layouts are chosen for quiet. The template carries flat magenta, green and
orange cards and several inverted covers; none of them is used. What is used:

    11  cover        dark, grid and logo, no gradient
    18  divider      dark, the calmest of the section cards
    30  one column   light, header over body
    32  two columns  light, body left and something on the right

A recorded step gets the divider as its ground and the film over the top, which
is the one place the template's furniture would fight the content: a terminal
filling the slide has no room for a footer across it.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import zipfile

EMU = 914400
SLIDE_W, SLIDE_H = 13.333, 7.5

SKILL = os.path.expanduser(
    '~/.claude/plugins/cache/anthropic-agent-skills/document-skills/'
    '34040c9c5685/skills/pptx/scripts')

# our layout -> the template slide to clone
SOURCE = {'cover': 'slide11.xml', 'section': 'slide18.xml', 'end': 'slide11.xml',
          'cast': 'slide18.xml', 'one': 'slide30.xml', 'two': 'slide32.xml'}

# The click sequences the Slidev deck runs, by slide title. Code lines are
# 1-based inside their block, exactly as talk.md writes them: ```yaml {all|3|4|6|5}
CLICKS = {
    'It is arithmetic, not a bug': [3, 4, 6, 5],
    'A readiness probe that passes review': [3],
}
# Slides the Slidev deck reveals a piece at a time rather than all at once.
REVEAL = {'The fix is three things, and only one is a probe'}
ACCENT = 'E97132'                     # the template theme's accent2

DIAGRAM = {'What is actually running': 'architecture', 'The loop': 'loop',
           'The question the probe was asking': 'probes',
           'The fix is three things, and only one is a probe': 'verdicts'}


# ── reading and writing one slide's XML ──────────────────────────────────────
def shapes(xml):
    """Every <p:sp> in the slide, in document order."""
    return re.findall(r'<p:sp>.*?</p:sp>', xml, re.S)


def ph_of(sp):
    m = re.search(r'<p:ph type="(\w+)"([^>]*)', sp)
    if not m:
        return None, None
    idx = re.search(r'idx="(\d+)"', m.group(2))
    return m.group(1), (idx.group(1) if idx else '')


def spid_of(sp):
    m = re.search(r'<p:cNvPr id="(\d+)"', sp)
    return m.group(1) if m else None


def paragraphs(lines, size=None, color=None, bullet=False, mono=False):
    """<a:p> runs. Styling stays out of the way unless a slide asks for it."""
    out = []
    for line in lines:
        rpr = '<a:rPr lang="en-US" dirty="0"'
        if size:
            rpr += f' sz="{int(size * 100)}"'
        if mono:
            rpr += '/><a:latin typeface="Courier New"/></a:rPr>'
            rpr = rpr.replace('/><a:latin', '><a:latin').replace('</a:rPr>', '</a:rPr>')
        else:
            rpr += '/>'
        if color:
            rpr = rpr.replace('/>', f'><a:solidFill><a:srgbClr val="{color}"/></a:solidFill></a:rPr>')
        ppr = '<a:pPr marL="0" indent="0"><a:buNone/></a:pPr>' if not bullet else ''
        text = (line.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;'))
        space = ' xml:space="preserve"' if text != text.strip() else ''
        out.append(f'<a:p>{ppr}<a:r>{rpr}<a:t{space}>{text}</a:t></a:r></a:p>')
    return ''.join(out) or '<a:p/>'


def set_text(xml, want_type, want_idx, body):
    """Replace the paragraphs of one placeholder, leaving the shape alone."""
    for sp in shapes(xml):
        t, i = ph_of(sp)
        if t != want_type or (want_idx is not None and i != want_idx):
            continue
        new = re.sub(r'(<p:txBody><a:bodyPr[^>]*/?>(?:</a:bodyPr>)?<a:lstStyle/>).*?(</p:txBody>)',
                     lambda m: m.group(1) + body + m.group(2), sp, flags=re.S)
        return xml.replace(sp, new, 1)
    return xml


def drop(xml, want_type, want_idx=None):
    for sp in shapes(xml):
        t, i = ph_of(sp)
        if t == want_type and (want_idx is None or i == want_idx):
            xml = xml.replace(sp, '', 1)
    return xml


def move(xml, want_type, want_idx, box):
    """Give a placeholder an explicit rectangle instead of the layout's."""
    x, y, w, h = [int(v * EMU) for v in box]
    frame = f'<a:xfrm><a:off x="{x}" y="{y}"/><a:ext cx="{w}" cy="{h}"/></a:xfrm>'
    for sp in shapes(xml):
        t, i = ph_of(sp)
        if t != want_type or (want_idx is not None and i != want_idx):
            continue
        if True:
            new = sp.replace('<p:spPr/>', f'<p:spPr>{frame}</p:spPr>', 1)
            if new == sp:
                new = re.sub(r'<p:spPr>', f'<p:spPr>{frame}', sp, count=1)
            return xml.replace(sp, new, 1)
    return xml


FOOTER = 'The probe that killed itself'     # the box is 2.58in; longer wraps to two lines

# A slide-number field, so PowerPoint counts rather than repeating the template's
# literal "1" on every slide. The cached value is what a reader sees before
# PowerPoint recalculates.
def slide_number(n):
    return ('<a:fld id="{B7A4E5C4-9A3F-4B1E-9C2D-1A2B3C4D5E6F}" type="slidenum">'
            f'<a:rPr lang="en-US"/><a:t>{n}</a:t></a:fld>')


def set_furniture(xml, n):
    """The template's own footer line and page number, filled in."""
    xml = set_text(xml, 'ftr', None, paragraphs([FOOTER]))
    for sp in shapes(xml):
        t, _ = ph_of(sp)
        if t != 'sldNum':
            continue
        new = re.sub(r'(<a:lstStyle/>).*?(</p:txBody>)',
                     lambda m: m.group(1) + '<a:p><a:r>' + slide_number(n) + '</a:r></a:p>' + m.group(2),
                     sp, flags=re.S)
        new = new.replace('<a:r>' + slide_number(n) + '</a:r>', slide_number(n))
        xml = xml.replace(sp, new, 1)
    return xml


def clean_layout(deck, layout):
    """Take the template's own leftovers out of a layout we are going to use.

    slideLayout30 and its neighbours carry a text box reading "<Placeholder
    Text>". It belongs to the layout rather than to any slide, so it prints on
    every slide built from it and cannot be removed slide by slide.
    """
    xml = deck.read(layout)
    dropped = 0
    for sp in shapes(xml):
        txt = ' '.join(re.findall(r'<a:t>([^<]*)</a:t>', sp))
        if 'Placeholder Text' in txt and '<p:ph ' not in sp:
            xml = xml.replace(sp, '', 1)
            dropped += 1
    if dropped:
        deck.write(layout, xml)
    return dropped


def next_id(xml):
    return max(int(n) for n in re.findall(r'<p:cNvPr id="(\d+)"', xml)) + 1


def add_pic(xml, rid, box, name='Picture'):
    x, y, w, h = [int(v * EMU) for v in box]
    i = next_id(xml)
    pic = (f'<p:pic><p:nvPicPr><p:cNvPr id="{i}" name="{name}"/><p:cNvPicPr>'
           f'<a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>'
           f'<p:blipFill><a:blip r:embed="{rid}"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
           f'<p:spPr><a:xfrm><a:off x="{x}" y="{y}"/><a:ext cx="{w}" cy="{h}"/></a:xfrm>'
           f'<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>')
    return xml.replace('</p:spTree>', pic + '</p:spTree>', 1)


def add_video(xml, rid_video, rid_media, rid_cover, box):
    """The shape PowerPoint recognises as a playable film.

    Three relationships and two namespaces: the OOXML video link, Microsoft's
    2007 media embed, and the poster as an ordinary image fill. Drop any of them
    and PowerPoint either refuses the file or shows a grey box.
    """
    x, y, w, h = [int(v * EMU) for v in box]
    i = next_id(xml)
    pic = (f'<p:pic><p:nvPicPr><p:cNvPr id="{i}" name="Recording">'
           f'<a:hlinkClick r:id="" action="ppaction://media"/></p:cNvPr>'
           f'<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr>'
           f'<a:videoFile r:link="{rid_video}"/><p:extLst><p:ext uri="{{DAA4B4D4-6D71-4841-9C94-3DE7FCFB9230}}">'
           f'<p14:media xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main" '
           f'r:embed="{rid_media}"/></p:ext></p:extLst></p:nvPr></p:nvPicPr>'
           f'<p:blipFill><a:blip r:embed="{rid_cover}"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
           f'<p:spPr><a:xfrm><a:off x="{x}" y="{y}"/><a:ext cx="{w}" cy="{h}"/></a:xfrm>'
           f'<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>')
    return xml.replace('</p:spTree>', pic + '</p:spTree>', 1)


# ── the package ──────────────────────────────────────────────────────────────
class Deck:
    def __init__(self, root):
        self.root = root

    def path(self, *p):
        return os.path.join(self.root, *p)

    def read(self, rel):
        with open(self.path(*rel.split('/')), encoding='utf-8') as f:
            return f.read()

    def write(self, rel, text):
        with open(self.path(*rel.split('/')), 'w', encoding='utf-8') as f:
            f.write(text)

    def clone(self, source):
        out = subprocess.run([sys.executable, os.path.join(SKILL, 'add_slide.py'),
                              self.root, source], capture_output=True, text=True)
        if out.returncode:
            raise SystemExit(out.stdout + out.stderr)
        m = re.search(r'(ppt/slides/slide\d+\.xml)', out.stdout)
        if not m:
            raise SystemExit('add_slide.py said: ' + out.stdout)
        return m.group(1)

    def rels_of(self, slide):
        name = slide.split('/')[-1]
        return f'ppt/slides/_rels/{name}.rels'

    def add_rel(self, slide, type_, target):
        rel = self.rels_of(slide)
        xml = self.read(rel)
        used = {int(n) for n in re.findall(r'Id="rId(\d+)"', xml)}
        rid = f'rId{max(used) + 1 if used else 1}'
        entry = f'<Relationship Id="{rid}" Type="{type_}" Target="{target}"/>'
        self.write(rel, xml.replace('</Relationships>', entry + '</Relationships>'))
        return rid

    def add_media(self, src, name):
        dst = self.path('ppt', 'media', name)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        ext = name.rsplit('.', 1)[1].lower()
        ct = self.read('[Content_Types].xml')
        if f'Extension="{ext}"' not in ct:
            kind = {'mp4': 'video/mp4', 'png': 'image/png', 'jpg': 'image/jpeg',
                    'jpeg': 'image/jpeg'}[ext]
            ct = ct.replace('<Default', f'<Default Extension="{ext}" ContentType="{kind}"/><Default', 1)
            self.write('[Content_Types].xml', ct)
        return f'../media/{name}'


VIDEO_REL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/video'
MEDIA_REL = 'http://schemas.microsoft.com/office/2007/relationships/media'
IMAGE_REL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/image'
NOTES_REL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide'

NOTES_XML = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
             '<p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
             ' xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
             ' xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
             '<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/>'
             '</p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="Notes Placeholder"/>'
             '<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr>'
             '</p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>{body}</p:txBody></p:sp>'
             '</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>')


def add_notes(deck, slide, text):
    """A notes part for one slide, with the deck's narration in it."""
    n = int(re.search(r'slide(\d+)\.xml', slide).group(1))
    name = f'notesSlide{n}.xml'
    body = paragraphs([l for l in text.splitlines() if l.strip()], bullet=True)
    os.makedirs(deck.path('ppt', 'notesSlides', '_rels'), exist_ok=True)
    deck.write(f'ppt/notesSlides/{name}', NOTES_XML.format(body=body))
    deck.write(f'ppt/notesSlides/_rels/{name}.rels',
               '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
               '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
               f'<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/'
               f'relationships/slide" Target="../slides/slide{n}.xml"/></Relationships>')
    ct = deck.read('[Content_Types].xml')
    over = (f'<Override PartName="/ppt/notesSlides/{name}" ContentType="application/vnd.'
            'openxmlformats-officedocument.presentationml.notesSlide+xml"/>')
    if over not in ct:
        deck.write('[Content_Types].xml', ct.replace('</Types>', over + '</Types>'))
    deck.add_rel(slide, NOTES_REL, f'../notesSlides/{name}')


def main():
    if len(sys.argv) != 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    work, template, out = sys.argv[1], sys.argv[2], sys.argv[3]
    deck_json = json.load(open(os.path.join(work, 'deck.json'), encoding='utf-8'))
    cuts = json.load(open('slides/public/casts/full.cuts.json', encoding='utf-8'))
    title_of = {c['step']: c['title'] for c in cuts['cuts']}

    root = os.path.join(work, 'tmpl')
    shutil.rmtree(root, ignore_errors=True)
    with zipfile.ZipFile(template) as z:
        z.extractall(root)
    deck = Deck(root)

    # Structure first, content second: add_slide.py copies a slide verbatim, so
    # cloning after an edit would clone the edit.
    plan = []
    for s in deck_json:
        if s['layout'] in ('cover', 'end'):
            kind = s['layout']
        elif s['layout'] == 'section':
            kind = 'section'
        elif s['step']:
            kind = 'cast'
        elif s['code'] or s.get('tables') or DIAGRAM.get(s['title']):
            kind = 'two'
        else:
            kind = 'one'
        plan.append((kind, s, deck.clone(SOURCE[kind])))

    # Only our slides remain in the show order; clean.py takes the rest away.
    pres = deck.read('ppt/presentation.xml')
    prels = deck.read('ppt/_rels/presentation.xml.rels')
    order = []
    for _, _, slide in plan:
        name = slide.split('/')[-1]
        rid = re.search(rf'Id="(rId\d+)"[^>]*Target="slides/{name}"', prels).group(1)
        order.append(rid)
    ids = ''.join(f'<p:sldId id="{256 + i}" r:id="{r}"/>' for i, r in enumerate(order))
    pres = re.sub(r'<p:sldIdLst>.*?</p:sldIdLst>', f'<p:sldIdLst>{ids}</p:sldIdLst>', pres, flags=re.S)
    deck.write('ppt/presentation.xml', pres)
    # The template's own forty-four slides leave the show order here, and their
    # relationships have to go with them: sweep() walks the rels, so a slide left
    # in the rels file is still reachable and still ships.
    kept = set(order)
    prels = re.sub(r'<Relationship Id="(rId\d+)"[^>]*Target="slides/[^"]+"[^>]*/>',
                   lambda m: m.group(0) if m.group(1) in kept else '', prels)
    deck.write('ppt/_rels/presentation.xml.rels', prels)

    # Every layout our slides point at, tidied once.
    seen, dropped = set(), 0
    for _, _, slide in plan:
        rels = deck.read(deck.rels_of(slide))
        m = re.search(r'Target="\.\./(slideLayouts/slideLayout\d+\.xml)"', rels)
        if m and m.group(1) not in seen:
            seen.add(m.group(1))
            dropped += clean_layout(deck, 'ppt/' + m.group(1))
    print(f'  {len(plan)} slides on {len(seen)} of the template\'s layouts'
          + (f', {dropped} leftover text boxes removed' if dropped else ''))

    for n, (kind, s, slide) in enumerate(plan, 1):
        fill(deck, work, kind, s, slide, title_of, n)

    prune_layouts(deck, seen)

    if os.path.exists(out):
        os.remove(out)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for base, _, files in os.walk(root):
            for f in files:
                full = os.path.join(base, f)
                z.write(full, os.path.relpath(full, root))
    return 0


# ── clicks ───────────────────────────────────────────────────────────────────
# The Slidev deck reveals these slides a piece at a time and walks a highlight
# down a code block. PowerPoint can do both, and both are done by paragraph
# rather than by position: a rectangle drawn over "line four" would have to know
# the template's font metrics, and it would be wrong the first time somebody
# edited a word.

def _par(inner, node, ident, delay='indefinite'):
    """One click step of the main sequence."""
    a, b, c = ident, ident + 1, ident + 2
    return (f'<p:par><p:cTn id="{a}" fill="hold"><p:stCondLst><p:cond delay="{delay}"/>'
            f'</p:stCondLst><p:childTnLst><p:par><p:cTn id="{b}" fill="hold">'
            f'<p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>'
            f'<p:par><p:cTn id="{c}" presetID="1" presetClass="{node[0]}" presetSubtype="0"'
            f' fill="hold" grpId="0" nodeType="{node[1]}"><p:stCondLst><p:cond delay="0"/>'
            f'</p:stCondLst><p:childTnLst>{inner}</p:childTnLst></p:cTn></p:par>'
            f'</p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>'), ident + 3


def appear(spid, para, ident):
    """Make one paragraph visible."""
    inner = (f'<p:set><p:cBhvr><p:cTn id="{ident + 3}" dur="1" fill="hold"/><p:tgtEl>'
             f'<p:spTgt spid="{spid}"><p:txEl><p:pRg st="{para}" end="{para}"/></p:txEl>'
             f'</p:spTgt></p:tgtEl><p:attrNameLst><p:attrName>style.visibility</p:attrName>'
             f'</p:attrNameLst></p:cBhvr><p:to><p:strVal val="visible"/></p:to></p:set>')
    step, nxt = _par(inner, ('entr', 'clickEffect'), ident)
    return step, nxt + 1


def recolour(spid, para, rgb, ident):
    """Turn one paragraph a colour, which is what highlighting a line of code is."""
    inner = (f'<p:animClr clrSpc="rgb"><p:cBhvr><p:cTn id="{ident + 3}" dur="500" fill="hold"/>'
             f'<p:tgtEl><p:spTgt spid="{spid}"><p:txEl><p:pRg st="{para}" end="{para}"/></p:txEl>'
             f'</p:spTgt></p:tgtEl><p:attrNameLst><p:attrName>style.color</p:attrName>'
             f'</p:attrNameLst></p:cBhvr><p:to><a:srgbClr val="{rgb}"/></p:to></p:animClr>')
    step, nxt = _par(inner, ('emph', 'clickEffect'), ident)
    return step, nxt + 1


def animate(xml, steps, builds):
    """Wrap a list of click steps into the slide's timing tree."""
    if not steps:
        return xml
    bld = ''.join(f'<p:bldP spid="{s}" grpId="0" build="p"/>' for s in sorted(builds))
    tree = ('<p:timing><p:tnLst><p:par><p:cTn id="1" dur="indefinite" restart="never"'
            ' nodeType="tmRoot"><p:childTnLst><p:seq concurrent="1" nextAc="seek">'
            '<p:cTn id="2" dur="indefinite" nodeType="mainSeq"><p:childTnLst>'
            + ''.join(steps) +
            '</p:childTnLst></p:cTn><p:prevCondLst><p:cond evt="onPrev" delay="0">'
            '<p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:prevCondLst><p:nextCondLst>'
            '<p:cond evt="onNext" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl></p:cond>'
            '</p:nextCondLst></p:seq></p:childTnLst></p:cTn></p:par></p:tnLst>'
            + (f'<p:bldLst>{bld}</p:bldLst>' if bld else '') + '</p:timing>')
    return xml.replace('</p:sld>', tree + '</p:sld>')


def add_clicks(xml, s):
    """The slide's click sequence, if the Slidev version had one."""
    steps, builds, ident = [], set(), 10
    body_id = code_id = None
    for sp in shapes(xml):
        t, i = ph_of(sp)
        if t == 'body' and i == '2':
            body_id = spid_of(sp)
        if t == 'body' and i == '10':
            code_id = spid_of(sp)

    lines = CLICKS.get(s['title'])
    if lines and code_id:
        # One click per highlighted line, in the order the talk walks them.
        for n in lines:
            step, ident = recolour(code_id, n - 1, ACCENT, ident)
            steps.append(step)

    if s['title'] in REVEAL and body_id:
        count = len(s['bullets']) or len([l for l in s['prose'].splitlines() if len(l) > 3][:5])
        # The first paragraph is on screen when the slide arrives; the rest wait.
        for n in range(1, count):
            step, ident = appear(body_id, n, ident)
            steps.append(step)
        if count > 1:
            builds.add(body_id)

    return animate(xml, steps, builds)


def prune_layouts(deck, used):
    """Drop the layouts this deck never points at.

    The template carries forty-eight of them and three masters, and the stock
    photography in the ones we do not use is most of its hundred and twenty
    megabytes. A layout is only reachable through its master's list, so the
    lists are rewritten first and clean.py collects what that orphans.
    """
    for name in sorted(os.listdir(deck.path('ppt', 'slideMasters'))):
        if not name.endswith('.xml'):
            continue
        part = f'ppt/slideMasters/{name}'
        rels = deck.read(f'ppt/slideMasters/_rels/{name}.rels')
        keep = []
        for m in re.finditer(r'<p:sldLayoutId[^>]*r:id="(rId\d+)"[^>]*/>', deck.read(part)):
            tgt = re.search(rf'Id="{m.group(1)}"[^>]*Target="\.\./(slideLayouts/[^"]+)"', rels)
            if tgt and tgt.group(1) in used:
                keep.append(m.group(0))
        xml = deck.read(part)
        if keep:
            xml = re.sub(r'<p:sldLayoutIdLst>.*?</p:sldLayoutIdLst>',
                         '<p:sldLayoutIdLst>' + ''.join(keep) + '</p:sldLayoutIdLst>', xml, flags=re.S)
            deck.write(part, xml)
            # The relationship has to go too. Reachability is walked through the
            # rels, so a layout dropped from the list but left in the rels file
            # is still reachable and its stock photography still ships.
            kept_ids = {re.search(r'r:id="(rId\d+)"', k).group(1) for k in keep}
            pruned = re.sub(
                r'<Relationship Id="(rId\d+)"[^>]*slideLayouts/[^>]*/>',
                lambda m: m.group(0) if m.group(1) in kept_ids else '', rels)
            deck.write(f'ppt/slideMasters/_rels/{name}.rels', pruned)
    sweep(deck)


def sweep(deck):
    """Delete every part nothing reaches any more.

    clean.py drops slides and their media but leaves a layout that a master has
    stopped listing, and the template's unused layouts carry two stock photographs
    of sixty-three megabytes between them. So reachability is walked from
    presentation.xml through the relationship graph, and whatever is not on it
    goes, content-type overrides included.
    """
    def rels_for(part):
        d, n = os.path.split(part)
        return f'{d}/_rels/{n}.rels'

    roots = ['ppt/presentation.xml']
    seen, queue = set(), list(roots)
    while queue:
        part = queue.pop()
        if part in seen:
            continue
        seen.add(part)
        rel = rels_for(part)
        if not os.path.exists(deck.path(*rel.split('/'))):
            continue
        seen.add(rel)
        for tgt in re.findall(r'Target="([^"]+)"', deck.read(rel)):
            if tgt.startswith(('http:', 'https:', '../../')):
                continue
            queue.append(os.path.normpath(os.path.join(os.path.dirname(part), tgt)).replace(os.sep, '/'))

    removed = 0
    for base, _, files in list(os.walk(deck.path('ppt'))):
        for f in files:
            full = os.path.join(base, f)
            rel = os.path.relpath(full, deck.root).replace(os.sep, '/')
            if rel in seen or rel.endswith('/.rels'):
                continue
            # presProps, viewProps and tableStyles are reached from presentation's
            # own rels; anything still unseen here is genuinely unreferenced.
            os.remove(full)
            removed += 1
    ct = deck.read('[Content_Types].xml')
    ct = re.sub(r'<Override PartName="/([^"]+)"[^>]*/>',
                lambda m: m.group(0) if m.group(1) in seen else '', ct)
    deck.write('[Content_Types].xml', ct)
    if removed:
        print(f'  {removed} unused parts dropped from the template')


def fill(deck, work, kind, s, slide, title_of, number):
    """One of our slides, written into its clone of a template slide."""
    xml = deck.read(slide)
    img = lambda n: os.path.join(work, 'img', n + '.png')

    if kind in ('cover', 'end'):
        xml = set_text(xml, 'ctrTitle', None, paragraphs([s['title']]))
        sub = [s['subtitle']] if s['subtitle'] else []
        seen = {s['subtitle'], s['title']}
        tail = [l for l in s['prose'].splitlines() if len(l) > 3 and l not in seen]
        # Two lines, not four: the subtitle box is 1.81in tall and anything
        # longer runs off the bottom of the slide rather than wrapping inside it.
        xml = set_text(xml, 'subTitle', '1', paragraphs(sub + tail[:2], size=13))
        xml = drop(xml, 'dt')
        if kind == 'end' and os.path.exists(img('qr')):
            rid = deck.add_rel(slide, IMAGE_REL, deck.add_media(img('qr'), 'qr.png'))
            xml = add_pic(xml, rid, (9.6, 2.4, 2.7, 2.7), 'QR')

    elif kind == 'section':
        xml = set_text(xml, 'ctrTitle', None, paragraphs([s['title']]))
        lead = [l for l in s['prose'].splitlines() if len(l) > 3][:2]
        xml = set_text(xml, 'subTitle', '1', paragraphs(lead))

    elif kind == 'cast':
        # The divider's ground, and the film over everything else on it.
        step = s['step']
        xml = move(xml, 'ctrTitle', None, (0.34, 0.16, 12.6, 0.42))
        xml = set_text(xml, 'ctrTitle', None,
                       paragraphs([f"{step}  ·  {title_of.get(step, '')}"], size=12))
        xml = drop(xml, 'subTitle')
        mp4 = os.path.join(work, 'video', step + '.mp4')
        cover = os.path.join(work, 'covers', step + '.jpg')
        if os.path.exists(mp4):
            target = deck.add_media(mp4, f'rec-{step}.mp4')
            rv = deck.add_rel(slide, VIDEO_REL, target)
            rm = deck.add_rel(slide, MEDIA_REL, target)
            rc = deck.add_rel(slide, IMAGE_REL, deck.add_media(cover, f'rec-{step}.jpg'))
            # 1920x1294 is the recording's own shape; height first keeps the
            # terminal as large as the slide allows without cropping it.
            # Left-aligned on the template's own margin rather than centred:
            # the layout prints "AWS User Groups" in the bottom right corner, and
            # a centred film of this shape lands on top of it.
            h = 6.72
            w = h * 1920 / 1294
            xml = add_video(xml, rv, rm, rc, (0.34, 0.62, w, h))

    else:
        xml = set_text(xml, 'title', None, paragraphs([s['title']]))
        lead = [l for l in s['prose'].splitlines() if len(l) > 3]
        left = s['bullets'] or lead[:5]
        if kind == 'one':
            # The layout's body is the left half, which leaves a checklist
            # sitting in a column with the other half of the slide empty.
            xml = move(xml, 'body', '2', (0.38, 1.87, 12.45, 4.4))
        xml = set_text(xml, 'body', '2', paragraphs(left, bullet=bool(s['bullets'])))
        if kind == 'two':
            right_box = (6.78, 1.86, 6.06, 4.4)
            diagram = DIAGRAM.get(s['title'])
            if s['code']:
                code = s['code'][0]['text'].split('\n')[:16]
                xml = set_text(xml, 'body', '10', paragraphs(code, size=11, mono=True))
            elif s.get('tables'):
                rows = s['tables'][0]
                flat = ['   '.join(r) for r in rows]
                xml = set_text(xml, 'body', '10', paragraphs(flat, size=13, mono=True))
            elif diagram and os.path.exists(img(diagram)):
                xml = drop(xml, 'body', '10')
                rid = deck.add_rel(slide, IMAGE_REL, deck.add_media(img(diagram), diagram + '.png'))
                xml = add_pic(xml, rid, right_box, diagram)
            else:
                xml = drop(xml, 'body', '10')

    if kind in ('one', 'two'):
        xml = set_furniture(xml, number)
        xml = add_clicks(xml, s)

    deck.write(slide, xml)
    if s['notes'].strip():
        add_notes(deck, slide, s['notes'])


if __name__ == '__main__':
    sys.exit(main())
