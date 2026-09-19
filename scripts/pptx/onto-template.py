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
SLIDE_W, SLIDE_H = 13.3333, 7.5
slide_cx, slide_cy = 12192000, 6858000   # replaced from the template

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
# Measured off the rendered PNGs: a diagram wider than about 2.2 does not belong
# in a half-slide column.
ASPECT = {'architecture': 3.00, 'loop': 2.02, 'probes': 2.65, 'verdicts': 2.77}
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
            rpr += f'/><a:latin typeface="{MONO}"/></a:rPr>'
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


# The template prints the programme's name rather than this event's. Both live
# in the layouts, so they are named once here rather than on twenty-three slides.
EVENT = 'AWS User Group Central Asia 2026, Tashkent'


def clean_layout(deck, layout):
    """Take the template's own leftovers out of a layout we are going to use,
    and put this event's name where the programme's generic one was.

    slideLayout30 and its neighbours carry a text box reading "<Placeholder
    Text>". It belongs to the layout rather than to any slide, so it prints on
    every slide built from it and cannot be removed slide by slide. The same is
    true of the "AWS User Groups" line in the corner of the covers and dividers.
    """
    xml = deck.read(layout)
    dropped = 0
    for sp in shapes(xml):
        txt = ' '.join(re.findall(r'<a:t>([^<]*)</a:t>', sp))
        if 'Placeholder Text' in txt and '<p:ph ' not in sp:
            xml = xml.replace(sp, '', 1)
            dropped += 1
    renamed = '<a:t>AWS User Groups</a:t>' in xml
    xml = xml.replace('<a:t>AWS User Groups</a:t>', f'<a:t>{EVENT}</a:t>')
    if dropped or renamed:
        deck.write(layout, xml)
    return dropped


# ── the kit ──────────────────────────────────────────────────────────────────
# The template's brand faces, which it embeds, so they are used rather than
# fought: Duospace is a real monospace and there is no reason to ship Courier
# New next to it. Sizes follow the deck's own hierarchy -- a title, a section
# label, body, and a caption that is allowed to be quiet.
MONO = 'Amazon Ember Duospace'
# The template embeds its faces as subsets: only the glyphs its own slides used.
# A plus sign was not among them, so "2 + 3" came out as "2 ✦ 3". Anything with
# arithmetic or punctuation the template never typed gets a complete face that
# every Office already ships.
SAFE = 'Calibri'
INK, MUTED = '0E2841', '6B7A88'
TEAL, ORANGE, SURFACE, LINE = '156082', 'E97132', 'F4F7F9', 'DCE4EA'
SZ_LABEL, SZ_BODY, SZ_CAPTION, SZ_STAT = 15, 16, 11, 40

# One vertical rhythm for every content slide, so the eye lands in the same
# places twenty-three times instead of hunting. The layout used to stop around
# four and a half inches and leave the bottom third empty on nearly every slide;
# these three lines are what fills it.
Y_LEDE, H_LEDE = 1.68, 0.62
Y_MAIN, H_MAIN = 2.50, 3.00
Y_CLOSE, H_CLOSE = 5.72, 0.62


def add_text(xml, box, runs, align='l', anchor='t', face=None):
    """A free text box. `runs` is a list of (text, size, colour, bold) tuples.

    `face` pins the typeface. Worth doing for anything with arithmetic in it: a
    substituted face turned the plus in "2 + 3 x 1" into a diamond, and the one
    number the slide exists for is not the place to find that out on stage.
    """
    x, y, w, h = [int(v * EMU) for v in box]
    i = next_id(xml)
    body = ''
    for text, size, colour, bold in runs:
        if text is None:
            body += '<a:p/>'
            continue
        t = text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        latin = f'<a:latin typeface="{face}"/>' if face else ''
        body += (f'<a:p><a:pPr algn="{align}" marL="0" indent="0"><a:buNone/></a:pPr>'
                 f'<a:r><a:rPr lang="en-US" sz="{int(size * 100)}" b="{1 if bold else 0}" dirty="0">'
                 f'<a:solidFill><a:srgbClr val="{colour}"/></a:solidFill>{latin}</a:rPr>'
                 f'<a:t>{t}</a:t></a:r></a:p>')
    sp = (f'<p:sp><p:nvSpPr><p:cNvPr id="{i}" name="Text {i}"/><p:cNvSpPr txBox="1"/>'
          f'<p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="{x}" y="{y}"/>'
          f'<a:ext cx="{w}" cy="{h}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>'
          f'<a:noFill/></p:spPr><p:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0"'
          f' bIns="0" anchor="{anchor}"><a:normAutofit/></a:bodyPr><a:lstStyle/>{body}'
          f'</p:txBody></p:sp>')
    return xml.replace('</p:spTree>', sp + '</p:spTree>', 1)


def add_shape(xml, box, prst='rect', fill=SURFACE, line=LINE, text=None,
              size=SZ_BODY, colour=INK, bold=False, face=None, adj=None):
    """One shape, and the id it was given, so an animation can find it later."""
    x, y, w, h = [int(v * EMU) for v in box]
    i = next_id(xml)
    av = f'<a:gd name="adj" fmla="val {adj}"/>' if adj else ''
    body = '<a:p/>'
    if text:
        t = text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        latin = f'<a:latin typeface="{face}"/>' if face else ''
        body = (f'<a:p><a:pPr algn="ctr" marL="0" indent="0"><a:buNone/></a:pPr><a:r>'
                f'<a:rPr lang="en-US" sz="{int(size * 100)}" b="{1 if bold else 0}" dirty="0">'
                f'<a:solidFill><a:srgbClr val="{colour}"/></a:solidFill>{latin}</a:rPr>'
                f'<a:t>{t}</a:t></a:r></a:p>')
    ln = (f'<a:ln w="12700"><a:solidFill><a:srgbClr val="{line}"/></a:solidFill></a:ln>'
          if line else '<a:ln><a:noFill/></a:ln>')
    sp = (f'<p:sp><p:nvSpPr><p:cNvPr id="{i}" name="Shape {i}"/><p:cNvSpPr/><p:nvPr/>'
          f'</p:nvSpPr><p:spPr><a:xfrm><a:off x="{x}" y="{y}"/><a:ext cx="{w}" cy="{h}"/></a:xfrm>'
          f'<a:prstGeom prst="{prst}"><a:avLst>{av}</a:avLst></a:prstGeom>'
          f'<a:solidFill><a:srgbClr val="{fill}"/></a:solidFill>{ln}</p:spPr>'
          f'<p:txBody><a:bodyPr anchor="ctr" lIns="45720" rIns="45720"/><a:lstStyle/>{body}'
          f'</p:txBody></p:sp>')
    return xml.replace('</p:spTree>', sp + '</p:spTree>', 1), str(i)


def add_card(xml, box, fill=SURFACE, line=LINE):
    """A quiet panel to put things on. No edge stripes, no accent bars."""
    x, y, w, h = [int(v * EMU) for v in box]
    i = next_id(xml)
    sp = (f'<p:sp><p:nvSpPr><p:cNvPr id="{i}" name="Card {i}"/><p:cNvSpPr/><p:nvPr/>'
          f'</p:nvSpPr><p:spPr><a:xfrm><a:off x="{x}" y="{y}"/><a:ext cx="{w}" cy="{h}"/></a:xfrm>'
          f'<a:prstGeom prst="roundRect"><a:avLst><a:gd name="adj" fmla="val 4000"/></a:avLst>'
          f'</a:prstGeom><a:solidFill><a:srgbClr val="{fill}"/></a:solidFill>'
          f'<a:ln w="9525"><a:solidFill><a:srgbClr val="{line}"/></a:solidFill></a:ln>'
          f'</p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp>')
    return xml.replace('</p:spTree>', sp + '</p:spTree>', 1)


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


def add_video_emu(xml, rid_video, rid_media, rid_cover, box_emu):
    """Same as add_video, but the rectangle is already in EMU."""
    return add_video(xml, rid_video, rid_media, rid_cover,
                     tuple(v / EMU for v in box_emu))


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
    global slide_cx, slide_cy
    size = re.search(r'sldSz cx="(\d+)" cy="(\d+)"', deck.read('ppt/presentation.xml'))
    slide_cx, slide_cy = int(size.group(1)), int(size.group(2))

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


def appear_shape(spid, ident, fade=True):
    """Bring a whole shape on, on a click. Fade rather than snap: six things
    snapping onto a slide one after another reads as a fault, not a build."""
    inner = (f'<p:animEffect transition="in" filter="fade"><p:cBhvr>'
             f'<p:cTn id="{ident + 3}" dur="400"/><p:tgtEl><p:spTgt spid="{spid}"/></p:tgtEl>'
             f'</p:cBhvr></p:animEffect>'
             f'<p:set><p:cBhvr><p:cTn id="{ident + 4}" dur="1" fill="hold"><p:stCondLst>'
             f'<p:cond delay="0"/></p:stCondLst></p:cTn><p:tgtEl><p:spTgt spid="{spid}"/></p:tgtEl>'
             f'<p:attrNameLst><p:attrName>style.visibility</p:attrName></p:attrNameLst>'
             f'</p:cBhvr><p:to><p:strVal val="visible"/></p:to></p:set>')
    step, nxt = _par(inner, ('entr', 'clickEffect'), ident)
    return step, nxt + 2


def appear_group(spids, ident):
    """Several shapes on one press, so a step of the loop arrives as one thing."""
    inner = ''
    n = ident + 3
    for spid in spids:
        inner += (f'<p:animEffect transition="in" filter="fade"><p:cBhvr>'
                  f'<p:cTn id="{n}" dur="400"/><p:tgtEl><p:spTgt spid="{spid}"/></p:tgtEl>'
                  f'</p:cBhvr></p:animEffect>'
                  f'<p:set><p:cBhvr><p:cTn id="{n + 1}" dur="1" fill="hold"><p:stCondLst>'
                  f'<p:cond delay="0"/></p:stCondLst></p:cTn><p:tgtEl><p:spTgt spid="{spid}"/>'
                  f'</p:tgtEl><p:attrNameLst><p:attrName>style.visibility</p:attrName>'
                  f'</p:attrNameLst></p:cBhvr><p:to><p:strVal val="visible"/></p:to></p:set>')
        n += 2
    step, _ = _par(inner, ('entr', 'clickEffect'), ident)
    return step, n + 1


def bold_reveal(spid, para, ident):
    """A phrase turning bold one letter at a time.

    Lifted from the edit the author made by hand on the arithmetic slide, which
    is the right instinct: the number a slide turns on should arrive rather than
    simply be there. PowerPoint calls it Bold Reveal -- emphasis preset 15,
    iterating over letters at 25ms, setting style.fontWeight on one paragraph.
    """
    inner = (f'<p:set><p:cBhvr override="childStyle"><p:cTn id="{ident + 3}" dur="indefinite"/>'
             f'<p:tgtEl><p:spTgt spid="{spid}"><p:txEl><p:pRg st="{para}" end="{para}"/></p:txEl>'
             f'</p:spTgt></p:tgtEl><p:attrNameLst><p:attrName>style.fontWeight</p:attrName>'
             f'</p:attrNameLst></p:cBhvr><p:to><p:strVal val="bold"/></p:to></p:set>')
    a, b, c = ident, ident + 1, ident + 2
    step = (f'<p:par><p:cTn id="{a}" fill="hold"><p:stCondLst><p:cond delay="indefinite"/>'
            f'</p:stCondLst><p:childTnLst><p:par><p:cTn id="{b}" fill="hold">'
            f'<p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>'
            f'<p:par><p:cTn id="{c}" presetID="15" presetClass="emph" presetSubtype="0"'
            f' grpId="0" nodeType="clickEffect"><p:stCondLst><p:cond delay="0"/></p:stCondLst>'
            f'<p:iterate type="lt"><p:tmAbs val="25"/></p:iterate>'
            f'<p:childTnLst>{inner}</p:childTnLst></p:cTn></p:par>'
            f'</p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>')
    return step, ident + 4


def appear_para(spid, para, ident):
    """One paragraph of a shape, on a press. What reveals code a line at a time."""
    inner = (f'<p:animEffect transition="in" filter="fade"><p:cBhvr>'
             f'<p:cTn id="{ident + 3}" dur="300"/><p:tgtEl><p:spTgt spid="{spid}">'
             f'<p:txEl><p:pRg st="{para}" end="{para}"/></p:txEl></p:spTgt></p:tgtEl>'
             f'</p:cBhvr></p:animEffect>'
             f'<p:set><p:cBhvr><p:cTn id="{ident + 4}" dur="1" fill="hold"><p:stCondLst>'
             f'<p:cond delay="0"/></p:stCondLst></p:cTn><p:tgtEl><p:spTgt spid="{spid}">'
             f'<p:txEl><p:pRg st="{para}" end="{para}"/></p:txEl></p:spTgt></p:tgtEl>'
             f'<p:attrNameLst><p:attrName>style.visibility</p:attrName></p:attrNameLst>'
             f'</p:cBhvr><p:to><p:strVal val="visible"/></p:to></p:set>')
    step, nxt = _par(inner, ('entr', 'clickEffect'), ident)
    return step, nxt + 2


def fly_in(spids, ident):
    """Up from the bottom edge, together. The author's choice for the panel that
    carries the number, and it earns the difference: a thing that arrives from
    somewhere reads as an answer, a thing that fades in reads as a footnote."""
    inner = ''
    n = ident + 3
    for spid in spids:
        inner += (f'<p:anim calcmode="lin" valueType="num"><p:cBhvr additive="base">'
                  f'<p:cTn id="{n}" dur="500" fill="hold"/><p:tgtEl><p:spTgt spid="{spid}"/>'
                  f'</p:tgtEl><p:attrNameLst><p:attrName>ppt_y</p:attrName></p:attrNameLst>'
                  f'</p:cBhvr><p:tavLst><p:tav tm="0"><p:val><p:strVal val="1+#ppt_h/2"/>'
                  f'</p:val></p:tav><p:tav tm="100000"><p:val><p:strVal val="#ppt_y"/></p:val>'
                  f'</p:tav></p:tavLst></p:anim>'
                  f'<p:set><p:cBhvr><p:cTn id="{n + 1}" dur="1" fill="hold"><p:stCondLst>'
                  f'<p:cond delay="0"/></p:stCondLst></p:cTn><p:tgtEl><p:spTgt spid="{spid}"/>'
                  f'</p:tgtEl><p:attrNameLst><p:attrName>style.visibility</p:attrName>'
                  f'</p:attrNameLst></p:cBhvr><p:to><p:strVal val="visible"/></p:to></p:set>')
        n += 2
    a, b, c = ident, ident + 1, ident + 2
    step = (f'<p:par><p:cTn id="{a}" fill="hold"><p:stCondLst><p:cond delay="indefinite"/>'
            f'</p:stCondLst><p:childTnLst><p:par><p:cTn id="{b}" fill="hold">'
            f'<p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>'
            f'<p:par><p:cTn id="{c}" presetID="2" presetClass="entr" presetSubtype="4"'
            f' fill="hold" grpId="0" nodeType="clickEffect"><p:stCondLst>'
            f'<p:cond delay="0"/></p:stCondLst><p:childTnLst>{inner}</p:childTnLst>'
            f'</p:cTn></p:par></p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>')
    return step, n + 1


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


# ── designed slides ──────────────────────────────────────────────────────────
# The generic path puts a title over a column of prose, which is the shape of
# slide this talk spent fifteen slides not being. These are laid out one at a
# time: what the slide is actually saying decides whether it wants cards, a
# number, or two labelled columns.

L, R = 0.39, 12.94                 # the template's own margins
TOP, BOT = 1.55, 6.45


def _cards(xml, items, y, h, gap=0.28):
    """A row of equal panels. Label, then the line, then the consequence.

    Returns the ids in pairs -- panel and its text -- so each one can be brought
    on by its own press rather than the whole row landing at once.
    """
    n = len(items)
    w = (R - L - gap * (n - 1)) / n
    ids = []
    for i, (label, line, tail, colour) in enumerate(items):
        x = L + i * (w + gap)
        xml, card = add_shape(xml, (x, y, w, h), 'roundRect', fill=SURFACE,
                              line=LINE, adj=4000)
        runs = [(label, SZ_LABEL, colour, True), (None, 0, INK, False),
                (line, SZ_BODY, INK, False)]
        if tail:
            runs += [(None, 0, INK, False), (tail, SZ_CAPTION, MUTED, False)]
        # Centred in the panel: top-aligned text in a three-inch card leaves the
        # bottom half of every card empty, which is the shape of slide this pass
        # exists to stop making.
        xml = add_text(xml, (x + 0.3, y + 0.28, w - 0.6, h - 0.56), runs, anchor='ctr')
        ids.append((card, str(int(card) + 1)))
    return xml, ids


def d_questions(xml, s, ctx):
    xml = add_text(xml, (L, Y_LEDE, R - L, H_LEDE),
                   [(s['prose'].splitlines()[0], 17, INK, False)])
    xml, ids = _cards(xml, [
        ('startup', 'has it finished booting?',
         'while it runs, the other two are not consulted at all', TEAL),
        ('liveness', 'is the process alive?',
         'a wrong answer restarts the container', ORANGE),
        ('readiness', 'can it serve right now?',
         'a wrong answer takes the pod out of the Service', TEAL),
    ], Y_MAIN, H_MAIN)
    tail = [l for l in s['prose'].splitlines() if l.startswith('Of everything')]
    last = None
    if tail:
        xml = add_text(xml, (L, Y_CLOSE, R - L, H_CLOSE), [(tail[0], 16, INK, False)])
        last = str(next_id(xml) - 1)
    steps, ident = [], 10
    for pair in ids:
        step, ident = fly_in(list(pair), ident)
        steps.append(step)
    if last:
        step, ident = appear_group([last], ident)
        steps.append(step)
    return animate(xml, steps, set())


def d_arithmetic(xml, s, ctx):
    """The manifest, the number it comes to, and what that costs.

    The lede is three boxes rather than one sentence because the middle one is
    the warm-up, and a phrase can only be emphasised on its own. The boxes keep
    the positions the author measured by hand in PowerPoint; estimating them
    from glyph widths would be a guess about a font this machine cannot render.
    """
    lines = [l for l in s['prose'].splitlines() if len(l) > 3]
    ids = []
    for text, box in [('The service warms up for', (0.43, 1.34, 2.30, 0.31)),
                      ('10 seconds.', (2.69, 1.34, 1.25, 0.31)),
                      ('Every number in this probe is defensible on its own.',
                       (3.91, 1.36, 4.63, 0.31))]:
        xml = add_text(xml, box, [(text, 15, INK, False)])
        ids.append(str(next_id(xml) - 1))
    warmup = ids[1]

    code = s['code'][0]['text'].split('\n')
    xml, card = add_shape(xml, (0.39, 2.35, 6.10, 2.90), 'roundRect',
                          fill=SURFACE, line=LINE, adj=4000)
    xml = add_text(xml, (0.67, 2.58, 5.55, 2.50), [(c, 11, INK, False) for c in code])
    code_id = str(next_id(xml) - 1)

    xml, stat_card = add_shape(xml, (7.0, 2.35, 5.94, 2.90), 'roundRect',
                               fill='FFFFFF', line=LINE, adj=4000)
    xml = add_text(xml, (7.30, 2.55, 5.64, 0.95),
                   [('2 + 3 x 1 = 5 s', SZ_STAT, ORANGE, True)], face=SAFE)
    stat = str(next_id(xml) - 1)
    xml = add_text(xml, (7.30, 3.55, 5.64, 1.20),
                   [('patience runs out at five, the service is ready at ten',
                     SZ_CAPTION, MUTED, False), (None, 0, INK, False),
                    ('The pod dies every single time, and nothing in the manifest is wrong.',
                     SZ_BODY, INK, True)])
    stat_note = str(next_id(xml) - 1)

    last = [l for l in lines if l.startswith('timeoutSeconds')]
    closing = None
    if last:
        xml = add_text(xml, (L, Y_CLOSE, R - L, H_CLOSE), [(last[0], 14, INK, False)])
        closing = str(next_id(xml) - 1)

    steps, ident = [], 10
    step, ident = appear_group(ids, ident); steps.append(step)
    step, ident = bold_reveal(warmup, 0, ident); steps.append(step)
    # The card and its first line together, then a line a press.
    step, ident = appear_group([card], ident); steps.append(step)
    for n in range(len(code)):
        step, ident = appear_para(code_id, n, ident)
        steps.append(step)
    step, ident = fly_in([stat_card, stat, stat_note], ident); steps.append(step)
    step, ident = bold_reveal(stat, 0, ident); steps.append(step)
    if closing:
        step, ident = appear_group([closing], ident); steps.append(step)
    return animate(xml, steps, set())


def d_review(xml, s, ctx):
    """The sentence nobody argues with, the manifest that says it, and the bill.

    The probe itself was missing from this slide: the yaml was extracted and
    then never placed, so the room was asked to take the cost of a probe it had
    not been shown.
    """
    lines = [l for l in s['prose'].splitlines() if len(l) > 3]
    xml = add_text(xml, (L, Y_LEDE, 6.10, 1.75),
                   [(lines[0], 17, INK, True), (None, 0, INK, False),
                    (lines[1], SZ_BODY, INK, False)])
    lede = str(next_id(xml) - 1)

    xml, stat_card = add_shape(xml, (L, 3.62, 6.10, 1.62), 'roundRect',
                               fill='FFFFFF', line=LINE, adj=4000)
    xml = add_text(xml, (L + 0.32, 3.84, 5.46, 1.2),
                   [('57', SZ_STAT, ORANGE, True),
                    ('max_connections on the database it was checking', SZ_CAPTION, MUTED, False)],
                   face=SAFE)
    stat = str(next_id(xml) - 1)

    code_id = None
    if s['code']:
        xml, code_card = add_shape(xml, (7.0, Y_LEDE, 5.94, 1.32), 'roundRect',
                                   fill=SURFACE, line=LINE, adj=6000)
        code = s['code'][0]['text'].split('\n')
        xml = add_text(xml, (7.28, Y_LEDE + 0.2, 5.4, 1.0),
                       [(c, 12, INK, False) for c in code])
        code_id = str(next_id(xml) - 1)

    rows = s.get('tables', [[]])[0]
    table = []
    if rows:
        xml, tbl_card = add_shape(xml, (7.0, 3.20, 5.94, 2.04), 'roundRect',
                                  fill='FFFFFF', line=LINE, adj=4000)
        table.append(tbl_card)
        cw = (5.94 - 0.6) / len(rows[0])
        for ri, row in enumerate(rows):
            for ci, cell in enumerate(row):
                head = ri == 0
                xml = add_text(xml, (7.3 + ci * cw, 3.42 + ri * 0.42, cw, 0.4),
                               [(cell, 11 if head else 16, MUTED if head else INK, head)])
                table.append(str(next_id(xml) - 1))

    tail = [l for l in lines if l.startswith('max_connections')]
    closing = None
    if tail:
        xml = add_text(xml, (L, Y_CLOSE, R - L, H_CLOSE), [(tail[0], 16, INK, False)])
        closing = str(next_id(xml) - 1)

    steps, ident = [], 10
    step, ident = appear_group([lede], ident); steps.append(step)
    if code_id:
        step, ident = appear_group([code_card], ident); steps.append(step)
        for n in range(len(s['code'][0]['text'].split('\n'))):
            step, ident = appear_para(code_id, n, ident); steps.append(step)
    if table:
        step, ident = appear_group(table, ident); steps.append(step)
    step, ident = fly_in([stat_card, stat], ident); steps.append(step)
    step, ident = bold_reveal(stat, 0, ident); steps.append(step)
    if closing:
        step, ident = appear_group([closing], ident); steps.append(step)
    return animate(xml, steps, set())


def d_fix(xml, s, ctx):
    lines = [l for l in s['prose'].splitlines() if len(l) > 3]
    parts, cur = [], None
    for l in lines:
        m = re.match(r'(\d) · (.+)', l)
        if m:
            cur = [m.group(1), m.group(2), []]
            parts.append(cur)
        elif cur is not None:
            cur[2].append(l)
    items = [(f"{n} · {head}", body[0] if body else '',
              body[1] if len(body) > 1 else '', TEAL if n != '3' else ORANGE)
             for n, head, body in parts[:3]]
    xml, ids = _cards(xml, items, Y_MAIN, H_MAIN)
    closing = [l for l in lines if l.startswith('Twelve workers')]
    last = None
    if closing:
        xml = add_text(xml, (L, Y_CLOSE, R - L, H_CLOSE), [(closing[0], 17, INK, True)])
        last = str(next_id(xml) - 1)
    steps, ident = [], 10
    for pair in ids:
        step, ident = fly_in(list(pair), ident)
        steps.append(step)
    if last:
        step, ident = appear_group([last], ident)
        steps.append(step)
    return animate(xml, steps, set())


def d_checklist(xml, s, ctx):
    """Two labelled groups, side by side, the way the slide is actually written."""
    lines = [l for l in s['prose'].splitlines() if len(l) > 3]
    bullets = set(s['bullets'])
    groups, cur = [], None
    for l in lines:
        if l not in bullets and len(l) < 40 and not l.endswith('.'):
            cur = (l, [])
            groups.append(cur)
        elif cur is not None and l in bullets:
            cur[1].append(l)
    if len(groups) < 2:
        return None
    w = (R - L - 0.6) / 2
    ids = []
    for i, (head, items) in enumerate(groups[:2]):
        x = L + i * (w + 0.6)
        xml = add_text(xml, (x, Y_LEDE, w, 0.45), [(head, 17, TEAL, True)])
        head_id = str(next_id(xml) - 1)
        runs = []
        for it in items:
            runs += [(it, SZ_BODY, INK, False), (None, 0, INK, False)]
        xml = add_text(xml, (x, Y_LEDE + 0.65, w, 3.85), runs)
        ids.append((head_id, str(next_id(xml) - 1)))
    # Whatever did not land in a column. Without this the closing line printed
    # twice: once at the bottom of the second group and once again underneath it.
    placed = {h for h, _ in groups[:2]} | {i for _, items in groups[:2] for i in items}
    tail = [l for l in lines if l not in placed]
    closing = None
    if tail:
        xml = add_text(xml, (L, Y_CLOSE, R - L, H_CLOSE), [(tail[-1], 17, INK, True)])
        closing = str(next_id(xml) - 1)

    # A column at a time, then the line that ends the slide.
    steps, ident = [], 10
    for pair in ids:
        step, ident = appear_group(list(pair), ident)
        steps.append(step)
    if closing:
        step, ident = bold_reveal(closing, 0, ident)
        steps.append(step)
    return animate(xml, steps, set())


def d_loop(xml, s, ctx):
    """The cascade, as shapes rather than a flat picture.

    It was a PNG, and a picture of a circle cannot show a circle turning. Six
    boxes and six arrows, one press each, so the room watches the loop close
    instead of being handed it finished.
    """
    NODES = [
        ('the probe asks the database', TEAL),
        ('replicas go NotReady', TEAL),
        ('workers stop consuming SQS', TEAL),
        ('queue depth grows', TEAL),
        ('KEDA adds workers', TEAL),
        ('Karpenter buys nodes', ORANGE),     # the only step with a price tag
    ]
    bw, bh = 3.52, 0.95
    xs = [0.62, 4.93, 9.24]
    top, bottom = 2.0, 4.72
    # Top row runs left to right, the bottom row runs back, and the two ends
    # join up: the same shape the driver prints in the terminal.
    where = [(xs[0], top), (xs[1], top), (xs[2], top),
             (xs[2], bottom), (xs[1], bottom), (xs[0], bottom)]
    arrows = [
        ('rightArrow', xs[0] + bw + 0.08, top + bh / 2 - 0.16, 0.72, 0.32),
        ('rightArrow', xs[1] + bw + 0.08, top + bh / 2 - 0.16, 0.72, 0.32),
        ('downArrow', xs[2] + bw / 2 - 0.16, top + bh + 0.12, 0.32, bottom - top - bh - 0.24),
        ('leftArrow', xs[1] + bw + 0.08, bottom + bh / 2 - 0.16, 0.72, 0.32),
        ('leftArrow', xs[0] + bw + 0.08, bottom + bh / 2 - 0.16, 0.72, 0.32),
        ('upArrow', xs[0] + bw / 2 - 0.16, top + bh + 0.12, 0.32, bottom - top - bh - 0.24),
    ]
    node_ids, arrow_ids = [], []
    for (label, colour), (x, y) in zip(NODES, where):
        xml, i = add_shape(xml, (x, y, bw, bh), 'roundRect', fill='FFFFFF',
                           line=colour, text=label, size=13, colour=INK, adj=14000)
        node_ids.append(i)
    for prst, x, y, w, h in arrows:
        xml, i = add_shape(xml, (x, y, w, h), prst, fill=MUTED, line=None)
        arrow_ids.append(i)

    lines = [l for l in s['prose'].splitlines() if len(l) > 3]
    if lines:
        xml = add_text(xml, (L, BOT - 0.5, R - L, 0.5), [(lines[0], 15, INK, True)])

    # One press per turn: the arrow into a box arrives with the box.
    steps, ident = [], 10
    step, ident = appear_group([node_ids[0]], ident)
    steps.append(step)
    for k in range(1, 6):
        step, ident = appear_group([arrow_ids[k - 1], node_ids[k]], ident)
        steps.append(step)
    step, ident = appear_group([arrow_ids[5]], ident)     # the loop closes
    steps.append(step)
    return animate(xml, steps, set())


def d_verdicts(xml, s, ctx):
    """The same failed check down two probes, as shapes rather than a picture.

    The slide's own sentence is that one failure costs two different things, so
    the two branches arrive one press at a time and the room can be asked which
    one it would rather have before the second appears.
    """
    lines = [l for l in s['prose'].splitlines() if len(l) > 3]
    xml = add_text(xml, (L, TOP, R - L, 0.5), [(lines[0], 16, INK, False)])

    root_w = 4.3
    xml, root = add_shape(xml, ((SLIDE_W - root_w) / 2, TOP + 0.55, root_w, 0.55),
                          'roundRect', fill=SURFACE, line=LINE,
                          text='a pod that is working fine', size=14, adj=20000)

    branches = [
        (0.62, ORANGE, 'liveness says no', 'kubelet KILLS the container',
         'work in flight dies  ·  the pool is rebuilt  ·  the cache is cold again',
         'irreversible  ·  one job: notice a process that will never recover'),
        (6.94, TEAL, 'readiness says no', 'the pod leaves the EndpointSlice',
         'it keeps running  ·  no traffic reaches it  ·  it comes back by itself',
         'reversible  ·  slow is a readiness question, never a liveness one'),
    ]
    groups = []
    for x, colour, head, verdict, detail, note in branches:
        bw = 5.77
        ids = []
        xml, a = add_shape(xml, (x + bw / 2 - 0.16, TOP + 1.20, 0.32, 0.42),
                           'downArrow', fill=MUTED, line=None)
        ids.append(a)
        xml, h1 = add_shape(xml, (x, TOP + 1.70, bw, 0.52), 'roundRect',
                            fill='FFFFFF', line=colour, text=head, size=14,
                            colour=colour, bold=True, adj=20000)
        ids.append(h1)
        xml, a2 = add_shape(xml, (x + bw / 2 - 0.16, TOP + 2.30, 0.32, 0.35),
                            'downArrow', fill=MUTED, line=None)
        ids.append(a2)
        xml, h2 = add_shape(xml, (x, TOP + 2.73, bw, 0.55), 'roundRect',
                            fill='FFFFFF', line=colour, text=verdict, size=14, adj=20000)
        ids.append(h2)
        xml = add_text(xml, (x + 0.1, TOP + 3.38, bw - 0.2, 0.8),
                       [(detail, SZ_CAPTION, MUTED, False), (None, 0, INK, False),
                        (note, SZ_CAPTION, colour, True)], align='ctr')
        ids.append(str(next_id(xml) - 1))
        groups.append(ids)

    tail = [l for l in lines if l.startswith('Which makes')]
    last = None
    if tail:
        # The branch captions end at 5.73in, so this starts below them rather
        # than across them.
        xml = add_text(xml, (L, 5.95, R - L, 0.5), [(tail[0], 15, INK, True)])
        last = str(next_id(xml) - 1)

    steps, ident = [], 10
    for ids in groups:
        step, ident = appear_group(ids, ident)
        steps.append(step)
    if last:
        step, ident = appear_group([last], ident)
        steps.append(step)
    return animate(xml, steps, set())


def d_architecture(xml, s, ctx):
    """What is running, revealed along the path a request takes.

    This one was left as a picture on the grounds that a reference drawing has
    no order to reveal it in. That was wrong: the order is the request. It
    arrives at the api, goes on the queue, a worker picks it up and reaches the
    database, and only then do the two autoscalers appear, watching. The
    database is the one box in the other colour because it is the wall
    everything in the next twenty minutes runs into.
    """
    lines = [l for l in s['prose'].splitlines() if len(l) > 3]
    if lines:
        xml = add_text(xml, (L, TOP, R - L, 0.5), [(lines[0], 16, INK, False)])

    bw, bh = 3.6, 1.0
    xs = [0.62, 4.62, 8.62]
    top, bot = 2.25, 4.55
    NODES = [
        # box, row, colour, label
        (xs[0], top, TEAL, 'api\n/work  /healthz  /ready'),
        (xs[1], top, TEAL, 'SQS work queue'),
        (xs[2], top, TEAL, 'worker\nSQS consumer'),
        (xs[2], bot, ORANGE, 'RDS PostgreSQL\nmax_connections 57'),
        (xs[1], bot, TEAL, 'KEDA\nreads queue depth'),
        (xs[0], bot, TEAL, 'Karpenter\nbuys spot nodes'),
    ]
    ids = []
    for x, y, colour, label in NODES:
        xml, i = add_shape(xml, (x, y, bw, bh), 'roundRect', fill='FFFFFF',
                           line=colour, text=label.replace('\n', '   ·   '),
                           size=13, colour=INK, adj=12000)
        ids.append(i)

    gap_x = xs[0] + bw + 0.04, xs[1] + bw + 0.04
    mid = bh / 2 - 0.16
    ARROWS = [
        ('rightArrow', gap_x[0], top + mid, 0.32, 0.32),          # api -> queue
        ('rightArrow', gap_x[1], top + mid, 0.32, 0.32),          # queue -> worker
        ('downArrow', xs[2] + bw / 2 - 0.16, top + bh + 0.1, 0.32, bot - top - bh - 0.2),
        ('downArrow', xs[1] + bw / 2 - 0.16, top + bh + 0.1, 0.32, bot - top - bh - 0.2),
        ('leftArrow', gap_x[0], bot + mid, 0.32, 0.32),           # KEDA -> Karpenter
    ]
    arrows = []
    for prst, x, y, w, h in ARROWS:
        xml, i = add_shape(xml, (x, y, w, h), prst, fill=MUTED, line=None)
        arrows.append(i)

    tail = lines[1] if len(lines) > 1 else None
    last = None
    if tail:
        xml = add_text(xml, (L, BOT - 0.75, R - L, 0.75), [(tail, SZ_CAPTION, MUTED, False)])
        last = str(next_id(xml) - 1)

    # The request first, then the machinery that reacts to it.
    order = [[ids[0]], [arrows[0], ids[1]], [arrows[1], ids[2]],
             [arrows[2], ids[3]], [arrows[3], ids[4]], [arrows[4], ids[5]]]
    steps, ident = [], 10
    for group in order:
        step, ident = appear_group(group, ident)
        steps.append(step)
    if last:
        step, ident = appear_group([last], ident)
        steps.append(step)
    return animate(xml, steps, set())


DESIGN = {
    'The loop': d_loop,
    'What is actually running': d_architecture,
    'The question the probe was asking': d_verdicts,
    'Something is asking your container questions': d_questions,
    'It is arithmetic, not a bug': d_arithmetic,
    'A readiness probe that passes review': d_review,
    'The fix is three things, and only one is a probe': d_fix,
    'The checklist · liveness and startup': d_checklist,
    'The checklist · readiness, and the blast radius': d_checklist,
}


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
        # Edge to edge, and nothing else on the slide. The film is padded to 16:9
        # when it is cut, so it fills the slide exactly; a caption or a footer
        # over it would be the template arguing with the terminal, and the step
        # number is already printed inside the recording by tmux.
        step = s['step']
        xml = drop(xml, 'ctrTitle')
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
            # Exact EMU rather than the rounded inches: 13.333 is 305 EMU short
            # of the slide, which is nothing to look at and still a hairline of
            # template showing down one edge of a full-bleed film.
            xml = add_video_emu(xml, rv, rm, rc, (0, 0, slide_cx, slide_cy))

    elif s['title'] == 'Alexander Dovnar':
        xml = set_text(xml, 'title', None, paragraphs([s['title']]))
        xml = drop(xml, 'body', '2')
        xml = drop(xml, 'body', '10')
        shots = []
        portrait = os.path.join(work, 'img', 'portrait.png')
        if os.path.exists(portrait):
            rid = deck.add_rel(slide, IMAGE_REL, deck.add_media(portrait, 'portrait.png'))
            xml = add_pic(xml, rid, (0.39, 1.68, 3.40, 3.40), 'Portrait')
            shots.append(str(next_id(xml) - 1))
        mark = os.path.join(work, 'img', 'logo.png')
        if os.path.exists(mark):
            rid = deck.add_rel(slide, IMAGE_REL, deck.add_media(mark, 'naviteq.png'))
            xml = add_pic(xml, rid, (0.39, 5.35, 1.90, 1.90 * 352 / 960), 'Naviteq')
            shots.append(str(next_id(xml) - 1))

        # prose carries the list items as well, so the lead-in and the links are
        # whatever is left once the bullets are taken out of it.
        bullets = set(s['bullets'])
        lead = [l for l in s['prose'].splitlines() if len(l) > 3 and l not in bullets]
        col = 4.15
        xml = add_text(xml, (col, 1.68, 8.70, 1.1), [(lead[0], 20, INK, False)])
        intro = str(next_id(xml) - 1)
        runs = []
        for it in s['bullets']:
            runs += [(it, 16, INK, False), (None, 0, INK, False)]
        xml = add_text(xml, (col, 3.00, 8.70, 2.5), runs)
        creds = str(next_id(xml) - 1)
        links = None
        if len(lead) > 1:
            xml = add_text(xml, (col, 5.55, 8.70, 0.5), [(lead[1], 12, MUTED, False)])
            links = str(next_id(xml) - 1)

        steps, ident = [], 10
        if shots:
            step, ident = appear_group(shots, ident); steps.append(step)
        step, ident = appear_group([intro], ident); steps.append(step)
        step, ident = appear_group([creds], ident); steps.append(step)
        if links:
            step, ident = appear_group([links], ident); steps.append(step)
        xml = animate(xml, steps, set())
        xml = set_furniture(xml, number)
        deck.write(slide, xml)
        if s['notes'].strip():
            add_notes(deck, slide, s['notes'])
        return

    elif s['title'] in DESIGN:
        # Laid out by hand: the slide's own shape rather than a column of prose.
        xml = set_text(xml, 'title', None, paragraphs([s['title']]))
        xml = drop(xml, 'body', '2')
        xml = drop(xml, 'body', '10')
        designed = DESIGN[s['title']](xml, s, None)
        xml = designed if designed is not None else xml
        xml = set_furniture(xml, number)
        if '<p:timing>' not in xml:
            xml = add_clicks(xml, s)
        deck.write(slide, xml)
        if s['notes'].strip():
            add_notes(deck, slide, s['notes'])
        return

    else:
        xml = set_text(xml, 'title', None, paragraphs([s['title']]))
        lead = [l for l in s['prose'].splitlines() if len(l) > 3]
        left = s['bullets'] or lead[:6]
        diagram = DIAGRAM.get(s['title'])
        # A wide diagram in the right-hand column is a wide picture in a tall box:
        # it fills the width and leaves two thirds of the height empty. Those get
        # the text across the top and the picture across the whole slide below.
        wide = diagram and ASPECT.get(diagram, 1) > 2.2
        if kind == 'one':
            # The layout's body is the left half, which leaves a checklist
            # sitting in a column with the other half of the slide empty.
            xml = move(xml, 'body', '2', (0.38, 1.8, 12.45, 4.6))
        elif wide:
            # Sized to the text rather than to a guess: a fixed shallow box clips
            # a six-line slide mid-word, which is how "budget the pool" came out
            # as "budget the pc". The picture takes whatever is left above the
            # footer.
            wide_h = min(2.6, 0.30 * len(left) + 0.25)
            xml = move(xml, 'body', '2', (0.38, 1.65, 12.45, wide_h))
        else:
            xml = move(xml, 'body', '2', (0.38, 1.8, 6.06, 4.6))
        xml = set_text(xml, 'body', '2',
                       paragraphs(left, bullet=bool(s['bullets']), size=16))
        if kind == 'two':
            if s['code']:
                xml = move(xml, 'body', '10', (6.78, 1.8, 6.06, 4.6))
                code = s['code'][0]['text'].split('\n')[:18]
                xml = set_text(xml, 'body', '10', paragraphs(code, size=12, mono=True))
            elif s.get('tables'):
                xml = move(xml, 'body', '10', (6.78, 1.8, 6.06, 4.6))
                flat = ['   '.join(r) for r in s['tables'][0]]
                xml = set_text(xml, 'body', '10', paragraphs(flat, size=14, mono=True))
            elif diagram and os.path.exists(img(diagram)):
                xml = drop(xml, 'body', '10')
                rid = deck.add_rel(slide, IMAGE_REL, deck.add_media(img(diagram), diagram + '.png'))
                ar = ASPECT.get(diagram, 1.5)
                if wide:
                    # Bounded by height, not width: the footer sits at 6.68in and
                    # a full-width picture of this shape lands on top of it.
                    top, bottom = 1.65 + wide_h + 0.3, 6.45
                    h = bottom - top
                    w = min(11.9, h * ar)
                    xml = add_pic(xml, rid, ((SLIDE_W - w) / 2, top, w, h), diagram)
                else:
                    w = 6.06
                    h = min(4.6, w / ar)
                    xml = add_pic(xml, rid, (6.78, 1.8 + (4.6 - h) / 2, w, h), diagram)
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
