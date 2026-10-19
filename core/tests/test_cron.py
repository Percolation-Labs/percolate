"""The Schedules screen's cron reader, checked without a database or a browser.

Run: python -m unittest discover -s tests -p test_cron.py

`ui/static/cron.js` is a transcription of `workflow.cron_matches_local` from
`specs/workflow-engine/schema.sql` §19, which exists so the screen can say what
an expression means and when it will next fire. A second implementation of
anything is a liability, so two things guard this one: these tests pin the
decisions the engine argues for, and `dev/cron_agrees.py` runs both matchers
over the same grid against a live database.

The decisions worth pinning are the ones a general-purpose cron library would
get differently: no names, no `@daily`, 0 and 7 both Sunday, and Vixie's rule
that a restricted day-of-month AND day-of-week fire on either.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import unittest
from pathlib import Path

STATIC = Path(__file__).resolve().parents[1] / "percolate_core" / "ui" / "static"
CRON = (STATIC / "cron.js").as_uri()


def call(body: str):
    """Evaluate an expression against cron.js and return the JSON result."""
    script = (f'import * as cron from {json.dumps(CRON)};\n'
              f'console.log(JSON.stringify((() => {{ {body} }})()));')
    out = subprocess.run(["node", "--input-type=module", "-e", script],
                         capture_output=True, text=True)
    if out.returncode:
        raise AssertionError(out.stderr.strip())
    return json.loads(out.stdout)


def throws(expr: str) -> str:
    return call(f'try {{ cron.parseCron({json.dumps(expr)}); return ""; }} '
                f'catch (e) {{ return e.message; }}')


@unittest.skipUnless(shutil.which("node"), "cron.js is JavaScript; nothing else should read it")
class CronTest(unittest.TestCase):
    def test_imports_nothing(self):
        """It is pure logic, so a bare node can load it and so can the audit."""
        self.assertNotIn("\nimport ", "\n" + (STATIC / "cron.js").read_text())

    def test_rejects_what_the_engine_rejects(self):
        for expr, fragment in [
            ("0 2 * * MON", "unsupported element"),   # names are not Vixie cron
            ("@daily", "expected 5 fields"),          # sugar needs an expansion table
            ("0 2 * *", "expected 5 fields"),
            ("0 2 * * * *", "expected 5 fields"),
            ("99 2 * * *", "out of range"),
            ("0 2 * * 8", "out of range"),
            ("*/0 2 * * *", "step must be >= 1"),
            ("0 2 * * 5-1", "out of range"),          # lo > hi
        ]:
            with self.subTest(expr=expr):
                self.assertIn(fragment, throws(expr))

    def test_accepts_every_supported_form(self):
        for expr in ("* * * * *", "0 2 * * *", "*/15 * * * *", "0 9-17 * * 1-5",
                     "10 5/10 * * *", "0 0 1,15 1-6/2 *", "5 4 * * 7"):
            with self.subTest(expr=expr):
                self.assertEqual(throws(expr), "")

    def test_n_slash_s_runs_to_the_end_of_the_range(self):
        """`5/10` in the hour field is 05:00 and 15:00, not 05:00 alone."""
        hours = call('return [5, 15, 25 % 24, 6].map(h => cron.fieldMatches("5/10", h, 0, 23));')
        self.assertEqual(hours, [True, True, False, False])

    def test_sunday_is_both_zero_and_seven(self):
        for field in ("0", "7"):
            with self.subTest(field=field):
                self.assertTrue(call(
                    f'return cron.matchesLocal("0 0 * * {field}", '
                    '{year:2026, month:9, day:13, hour:0, minute:0, dow:0});'))

    def test_vixie_or_rule(self):
        """`0 0 13 * 5` is the 13th OR any Friday. Not Friday the 13th."""
        # 2026-09-11 is a Friday and not the 13th; 2026-09-13 is the 13th, a Sunday.
        friday = call('return cron.matchesLocal("0 0 13 * 5", '
                      '{year:2026, month:9, day:11, hour:0, minute:0, dow:5});')
        thirteenth = call('return cron.matchesLocal("0 0 13 * 5", '
                          '{year:2026, month:9, day:13, hour:0, minute:0, dow:0});')
        self.assertTrue(friday, "a Friday that is not the 13th must fire")
        self.assertTrue(thirteenth, "the 13th that is not a Friday must fire")

    def test_the_or_rule_is_stated_in_words(self):
        """The description exists to stop somebody reading that as an AND."""
        self.assertIn(" or ", call('return cron.describeCron("0 0 13 * 5");'))

    def test_descriptions(self):
        for expr, expected in [
            ("0 2 * * *", "at 02:00, every day"),
            ("*/15 * * * *", "every 15 minutes, every day"),
            ("0 9-17 * * 1-5", "every hour on the hour from 09:00 to 17:00, on weekdays"),
            ("0 8 1,15 * *", "at 08:00, on the 1st and 15th"),
            ("0 0 1 1 *", "at 00:00, on the 1st in January"),
        ]:
            with self.subTest(expr=expr):
                self.assertEqual(call(f'return cron.describeCron({json.dumps(expr)});'), expected)

    def test_a_skipped_local_minute_has_no_instant(self):
        """01:30 does not happen in London on 2027-03-28. Do not invent it."""
        fires = call('return cron.nextFires("30 1 28 3 *", "Europe/London", 1, Date.UTC(2027, 2, 1));')
        self.assertEqual(len(fires), 1)
        self.assertIsNone(fires[0]["instant"])
        self.assertIn("skipped", fires[0]["note"])

    def test_a_repeated_hour_reads_differently_for_a_poll(self):
        """`cron_is_wall_clock`: an appointment fires once, a poll fires twice."""
        appointment = call('return cron.nextFires("30 1 25 10 *", "Europe/London", 1, Date.UTC(2026, 9, 1))[0].note;')
        poll = call('return cron.nextFires("*/30 * * * *", "Europe/London", 1, Date.UTC(2026, 9, 25, 0, 15))[0].note;')
        self.assertIn("once", appointment)
        self.assertIn("both", poll)
        self.assertNotEqual(appointment, poll)

    def test_fire_times_respect_the_zone(self):
        """02:00 London in September is 01:00Z; the schedule means the wall clock."""
        fires = call('return cron.nextFires("0 2 * * *", "Europe/London", 1, Date.UTC(2026, 8, 10, 12, 0));')
        self.assertEqual(fires[0]["local"]["hour"], 2)
        self.assertTrue(fires[0]["instant"] % 86400000 == 3600000,
                        "expected 01:00Z for 02:00 British Summer Time")

    def test_overlap_policy_matches_the_check_constraint(self):
        """`workflow.schedules` allows skip and allow. A draft of anything else
        is rejected by the database, so the assistant may not propose it."""
        schema = (STATIC / "schedule-assist.js").read_text()
        self.assertIn('enum: ["skip", "allow", ""]', schema)
        self.assertNotIn("queue", schema)


if __name__ == "__main__":
    unittest.main()
