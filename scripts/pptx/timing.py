#!/usr/bin/env python3
"""Make the recordings start themselves when their slide comes up.

    scripts/pptx/timing.py slides/talk.pptx [PAUSE_CLICKS]

pptxgenjs writes the video shape and nothing else, so PowerPoint falls back to
"start on click" -- the slide opens and the terminal sits there until somebody
finds the play button with a mouse. What decides this is the <p:timing> tree,
which pptxgenjs does not write at all, so it gets added here.

The shape is a main sequence of click steps. A step whose start condition is
delay="0" fires the moment the slide arrives; delay="indefinite" waits for the
presenter. So step one plays the video on entry, and any further steps are
togglePause commands that the clicker walks through.

PAUSE_CLICKS is how many of those to add, and it is not free: a step that is
never used still has to be clicked past before the slide will advance. Two
steps buy pause-then-resume at the cost of two extra clicks on a slide the
presenter chose not to pause. Zero, the default, means the recording plays and
the next click moves on.
"""

import re
import shutil
import sys
import zipfile

# A media command inside one click step. `dur="1"` is what PowerPoint writes:
# the command is instantaneous, the node just has to exist for a tick.
CMD = ('<p:par><p:cTn id="{i}" presetID="1" presetClass="mediacall" presetSubtype="0"'
       ' fill="hold" nodeType="{node}"><p:stCondLst><p:cond delay="0"/></p:stCondLst>'
       '<p:childTnLst><p:cmd type="call" cmd="{cmd}"><p:cBhvr><p:cTn id="{j}" dur="1"'
       ' fill="hold"/><p:tgtEl><p:spTgt spid="{spid}"/></p:tgtEl></p:cBhvr></p:cmd>'
       '</p:childTnLst></p:cTn></p:par>')

STEP = ('<p:par><p:cTn id="{i}" fill="hold"><p:stCondLst><p:cond delay="{delay}"/>'
        '</p:stCondLst><p:childTnLst><p:par><p:cTn id="{j}" fill="hold">'
        '<p:stCondLst><p:cond delay="0"/></p:stCondLst><p:childTnLst>{body}'
        '</p:childTnLst></p:cTn></p:par></p:childTnLst></p:cTn></p:par>')


def timing(spid, pause_clicks):
    """The <p:timing> tree for one slide holding one video."""
    n = [2]                      # id 1 is the timing root
    def nid():
        n[0] += 1
        return n[0]

    steps = []
    # Step one: play, the moment the slide is on screen.
    i, j = nid(), nid()
    steps.append(STEP.format(i=i, j=j, delay='0',
                             body=CMD.format(i=nid(), j=nid(), spid=spid,
                                             cmd='playFrom(0.0)', node='afterEffect')))
    # The rest: one toggle per click.
    for _ in range(pause_clicks):
        i, j = nid(), nid()
        steps.append(STEP.format(i=i, j=j, delay='indefinite',
                                 body=CMD.format(i=nid(), j=nid(), spid=spid,
                                                 cmd='togglePause', node='clickEffect')))

    # The <p:video> node is what tells PowerPoint this shape is a media object
    # it owns; without it the commands above have nothing to talk to.
    media = ('<p:video><p:cMediaNode vol="80000"><p:cTn id="{i}" fill="hold" display="0">'
             '<p:stCondLst><p:cond delay="indefinite"/></p:stCondLst></p:cTn>'
             '<p:tgtEl><p:spTgt spid="{spid}"/></p:tgtEl></p:cMediaNode></p:video>'
             ).format(i=nid(), spid=spid)

    return ('<p:timing><p:tnLst><p:par><p:cTn id="1" dur="indefinite" restart="never"'
            ' nodeType="tmRoot"><p:childTnLst><p:seq concurrent="1" nextAc="seek">'
            '<p:cTn id="2" dur="indefinite" nodeType="mainSeq"><p:childTnLst>'
            + ''.join(steps) +
            '</p:childTnLst></p:cTn><p:prevCondLst><p:cond evt="onPrev" delay="0">'
            '<p:tgtEl><p:sldTgt/></p:tgtEl></p:cond></p:prevCondLst>'
            '<p:nextCondLst><p:cond evt="onNext" delay="0"><p:tgtEl><p:sldTgt/></p:tgtEl>'
            '</p:cond></p:nextCondLst></p:seq>' + media +
            '</p:childTnLst></p:cTn></p:par></p:tnLst></p:timing>')


def video_spid(xml):
    """The shape id of the picture that carries a video, or None."""
    for pic in re.findall(r'<p:pic>.*?</p:pic>', xml, re.S):
        if '<a:videoFile' not in pic:
            continue
        m = re.search(r'<p:cNvPr id="(\d+)"', pic)
        if m:
            return m.group(1)
    return None


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    path = sys.argv[1]
    pause_clicks = int(sys.argv[2]) if len(sys.argv) > 2 else 0

    src = zipfile.ZipFile(path)
    items = {n: src.read(n) for n in src.namelist()}
    src.close()

    touched = 0
    for name in list(items):
        if not re.fullmatch(r'ppt/slides/slide\d+\.xml', name):
            continue
        xml = items[name].decode('utf-8')
        if '<p:timing>' in xml:
            continue
        spid = video_spid(xml)
        if not spid:
            continue
        items[name] = xml.replace('</p:sld>', timing(spid, pause_clicks) + '</p:sld>').encode('utf-8')
        touched += 1

    tmp = path + '.tmp'
    with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as out:
        for name, data in items.items():
            out.writestr(name, data)
    shutil.move(tmp, path)

    plural = '' if touched == 1 else 's'
    extra = f', {pause_clicks} pause click{"" if pause_clicks == 1 else "s"}' if pause_clicks else ''
    print(f'  {touched} recording{plural} now start on their own{extra}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
