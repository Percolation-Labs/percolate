#!/usr/bin/env python3
"""Generate the ingestion fixtures. Five formats, one story.

GENERATED RATHER THAN COMMITTED, for the reason 05-corpus-sample.sql gives for
its literal vectors: a fixture you cannot regenerate is a fixture nobody can
check. A PDF in git is 40KB of opaque bytes that a reviewer has to take on
trust; this file is the same document as forty lines of prose plus the two
lines that make it a PDF.

Each fact lives in EXACTLY ONE file, so a question can only be answered from
the format that carries it:

    r7-field-notice.md      the serial range          markdown
    actuator-teardown.pdf   the temperature threshold pdf
    supplier-review.docx    the longest lead time     docx, in a table
    incidents.csv           the downtime totals       tabular -> parquet
    ops-briefing.wav        the eleven-day pause      audio -> transcript

    python3 dev/tests/content/fixtures.py /tmp/p8-fixtures
"""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys

NOTICE = """# Field Notice FN-2211: R7 harmonic drive

## Affected units

Every R7 articulated arm with a serial number between R7-4400 and R7-4913 is
in scope for this notice. Units outside that range use the revised drive and
are unaffected. The serial number is stamped on the collar below the second
joint, not on the controller, and a controller swap does not change it.

## What is happening

Sites running continuous duty cycles report a rising position error on the
third axis after roughly nine months of service. The error is small at first
and grows non-linearly. Left alone it ends as a stall under load, which trips
the safety contactor and stops the cell.

The failure is mechanical and it is in the harmonic drive assembly. It is not
a controller fault, and several sites lost a week replacing controllers before
we understood that.

## What to do now

Do not change the duty cycle as a mitigation. Reducing cycle rate delays the
onset and does not prevent it, and it makes the fleet harder to schedule for
the replacement programme. Log the position error weekly and send the logs
with the unit's serial number.
## Replacement programme

Replacement is by site, not by unit, because the fixture that presses the new
drive is shipped between sites and takes two days to set up and calibrate. A
site with four affected arms and a site with one therefore cost nearly the
same, and scheduling by unit count is how the first pass produced a plan that
had the fixture crossing the country twice.

Each site loses its affected cells for the duration. Cells that share a
controller with an affected arm keep running; the controller was never the
problem and nothing in this notice requires touching one.

## What we are not doing

We are not recalling controllers. We are not asking sites to reduce duty
cycles. We are not shipping spares ahead of the fixture, because a spare drive
sitting on a shelf at a site with no fixture is inventory rather than
mitigation, and the first version of this plan did exactly that at three
sites.

## Reporting

Send weekly position-error logs with the serial number of every affected arm,
including arms that show no error yet. The units that have not moved are the
ones that tell us whether the threshold model is right, and a report of only
the failures is a sample of failures.
"""

TEARDOWN_PAGES = [
    ("Teardown report: R7 third-axis harmonic drive",
     """We disassembled four returned drives from three sites. All four show the
same wear pattern on the flexspline, and all four had lost grease from the
bearing race into the cavity behind the labyrinth seal.

The mechanism is thermal. Grease migration past the labyrinth seal begins at a
sustained case temperature of 78 degrees Celsius. Below that the seal holds for
the design life. Above it, the loss is roughly linear in time above threshold,
which is why continuous-duty sites see this and shift-pattern sites do not."""),
    ("What we changed",
     """The revised drive is a drop-in. Same envelope, same mounting, same
gear ratio, and the wiring loom is untouched. Sites do not need to re-teach
positions after a replacement, and four sites that re-taught anyway lost two
days each to a precaution nobody had asked for.

The contact seal costs about four watts of additional drag at full speed. That
is inside the motor's margin at every duty cycle we ship, and it is the reason
the case runs cooler rather than hotter despite the extra friction: the grease
stays where it does its job."""),
    ("Open questions",
     """We do not know why Bellhaven's returns are worse than the temperature
model predicts. Their case temperatures are the lowest of the three sites and
their failure rate is the highest, which is the opposite of what this report
argues, and it is recorded here rather than left out because it is the one
measurement that would falsify the whole account.

The wave generator bearing has not been ruled out as a contributing cause. All
four teardowns had lost grease and all four had bearing wear; nothing here
establishes which came first."""),
    ("Measurements",
     """Case temperature was logged at the drive housing, not at the motor, and
the difference between those two points is about 11 degrees under load. A site
measuring at the motor and seeing 70 degrees is at the threshold.

Replacement drives use a contact seal and a higher-temperature grease. We have
run two of them to 1,900 hours at 92 degrees with no measurable loss."""),
]

SUPPLIERS = [
    ("Supplier", "Part", "Lead time (weeks)", "Qualified"),
    ("Ravensworth Precision", "Flexspline, revised", "6", "yes"),
    ("Kestrel Components", "Contact seal kit", "3", "yes"),
    ("Bellhaven Metals", "Wave generator bearing", "19", "no"),
    ("Ardsley Tool", "Housing, machined", "8", "yes"),
]

INCIDENTS = """site,date,units_affected,downtime_hours
Ravensworth,2026-03-11,4,18.5
Ravensworth,2026-04-02,2,6.0
Kestrel,2026-04-19,7,44.25
Bellhaven,2026-05-08,1,3.5
Kestrel,2026-06-01,3,12.0
Ardsley,2026-06-27,5,27.75
"""

BRIEFING = ("Operations briefing. The Kestrel line will pause for eleven days "
            "beginning on the fourth of November, while we replace harmonic "
            "drives on the affected units. Ravensworth continues on shift "
            "pattern throughout. Nothing else in the plan changes.")


def write_markdown(out: pathlib.Path) -> None:
    (out / "r7-field-notice.md").write_text(NOTICE)


def write_pdf(out: pathlib.Path) -> None:
    import pymupdf

    doc = pymupdf.open()
    for title, body in TEARDOWN_PAGES:
        page = doc.new_page()
        page.insert_text((60, 80), title, fontsize=16)
        y = 120
        # insert_textbox wraps; insert_text does not, and a PDF whose lines run
        # off the page is a fixture that tests the clipping, not the parser.
        page.insert_textbox(pymupdf.Rect(60, y, 540, 760), body, fontsize=11)
    doc.save(out / "actuator-teardown.pdf")
    doc.close()


def write_docx(out: pathlib.Path) -> None:
    import docx

    d = docx.Document()
    d.add_heading("Supplier review: R7 replacement programme", level=1)
    d.add_paragraph(
        "Lead times below are confirmed as of this quarter. The programme is "
        "gated by the longest of them, and one line is not yet qualified.")
    d.add_heading("Lead times", level=2)
    table = d.add_table(rows=len(SUPPLIERS), cols=len(SUPPLIERS[0]))
    for r, row in enumerate(SUPPLIERS):
        for c, value in enumerate(row):
            table.cell(r, c).text = value
    d.add_heading("Recommendation", level=2)
    d.add_paragraph(
        "Dual-source the wave generator bearing. A nineteen week lead time on "
        "an unqualified line is the whole of the schedule risk.")
    d.save(out / "supplier-review.docx")


def write_csv(out: pathlib.Path) -> None:
    (out / "incidents.csv").write_text(INCIDENTS)


def write_wav(out: pathlib.Path) -> bool:
    """Speech, via macOS `say`. Returns False where that does not exist.

    The audio fixture is the one that cannot be generated portably, and it is
    the one worth having: a transcription test against a synthesised tone
    proves the plumbing and nothing about whether the transcript is words. So
    where there is no TTS this returns False and the caller SKIPS the audio
    case loudly rather than substituting something that passes.
    """
    if not shutil.which("say") or not shutil.which("afconvert"):
        return False
    aiff = out / "_briefing.aiff"
    subprocess.run(["say", "-o", str(aiff), BRIEFING], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                    str(aiff), str(out / "ops-briefing.wav")], check=True)
    aiff.unlink()
    return True


def build(out: pathlib.Path) -> list[pathlib.Path]:
    out.mkdir(parents=True, exist_ok=True)
    write_markdown(out)
    write_pdf(out)
    write_docx(out)
    write_csv(out)
    made = ["r7-field-notice.md", "actuator-teardown.pdf", "supplier-review.docx",
            "incidents.csv"]
    if write_wav(out):
        made.append("ops-briefing.wav")
    else:
        print("no `say`/`afconvert` on this machine -- skipping the audio fixture",
              file=sys.stderr)
    return [out / m for m in made]


if __name__ == "__main__":
    target = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/p8-fixtures")
    for p in build(target):
        print(f"{p}  {p.stat().st_size} bytes")
