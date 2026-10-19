/* Cron in the two directions a person needs it, plus the assistant.
 *
 * The Schedules screen posted a five-field string straight into
 * `workflow.schedule_workflow` and rendered it back verbatim, so authoring a
 * schedule and reading somebody else's both required parsing cron by eye.
 *
 * WHY THE MATCHER IS REIMPLEMENTED HERE, which is the thing to be suspicious
 * of: a preview that disagrees with the engine is worse than no preview. So
 * `matchesLocal` is a transcription of `workflow.cron_matches_local`
 * (`specs/workflow-engine/schema.sql` §19) rather than a general cron library,
 * and it reproduces the same three decisions that file argues for:
 *
 *   1. No names (`MON`, `JAN`) and no `@daily` sugar. The engine rejects them,
 *      so accepting them here would draft expressions the database refuses.
 *   2. Both 0 and 7 mean Sunday, so Sunday is tested twice.
 *   3. Vixie's OR rule: when day-of-month AND day-of-week are both restricted,
 *      a match on either fires. `0 0 13 * 5` is the 13th *or* any Friday, not
 *      Friday the 13th. `describeCron` says that out loud, because it is the
 *      mistake this screen exists to stop somebody making.
 *
 * THIS FILE IMPORTS NOTHING, so the matcher can be checked against the
 * database's own function by a bare `node` — which is how the differential
 * test in `tests/test_cron_agrees_with_engine.py` runs at all.
 *
 * The engine matches a local wall clock and never stores a next-run time — its
 * own comment explains that a cached derivation goes stale at a DST boundary.
 * `nextFires` therefore enumerates LOCAL minutes and converts each to an
 * instant, and where a local minute does not exist or happens twice in the
 * chosen zone it says so on that row instead of inventing one. That is the
 * preview's whole job: show the wall clock the expression is talking about.
 */

const FIELDS = [
  { name: "minute", min: 0, max: 59 },
  { name: "hour", min: 0, max: 23 },
  { name: "day-of-month", min: 1, max: 31 },
  { name: "month", min: 1, max: 12 },
  { name: "day-of-week", min: 0, max: 7 },
];

/** One field against one integer. Mirrors `workflow.cron_field_matches`. */
export function fieldMatches(field, value, min, max, label) {
  let matched = false;
  for (const raw of String(field).trim().split(",")) {
    const part = raw.trim();
    if (part === "") throw new Error(`cron: empty element in field "${field}"`);

    let step = 1;
    let range = part;
    if (part.includes("/")) {
      const [head, tail] = [part.slice(0, part.indexOf("/")), part.slice(part.indexOf("/") + 1)];
      range = head;
      if (!/^\d+$/.test(tail)) throw new Error(`cron: bad step in "${part}"`);
      step = Number(tail);
      if (step < 1) throw new Error(`cron: step must be >= 1 in "${part}"`);
    }

    let lo, hi;
    if (range === "*") { lo = min; hi = max; }
    else if (/^\d+-\d+$/.test(range)) { [lo, hi] = range.split("-").map(Number); }
    else if (/^\d+$/.test(range)) {
      lo = Number(range);
      /* `n/s` means "from n to the end of the range, every s"; a bare `n` is
         itself. The engine's rule, and the reason 5/10 is not just 5. */
      hi = step > 1 ? max : lo;
    } else {
      throw new Error(`cron: unsupported element "${part}" in field "${label || field}"`);
    }

    if (lo < min || hi > max || lo > hi) {
      throw new Error(`cron: "${part}" out of range ${min}-${max} in field "${label || field}"`);
    }
    if (value >= lo && value <= hi && (value - lo) % step === 0) matched = true;
  }
  return matched;
}

/** Split and validate all five fields. Throws the way the engine throws. */
export function parseCron(expr) {
  const parts = String(expr).trim().split(/\s+/).filter(Boolean);
  if (parts.length !== 5) {
    throw new Error(`cron: expected 5 fields (minute hour day-of-month month day-of-week), `
      + `got ${parts.length} in "${expr}"`);
  }
  /* Every field is validated even when an earlier one already decided the
     answer. The engine's comment records why: short-circuiting made validity
     depend on the clock, so a bad day-of-week was accepted at 09:04 and failed
     once a minute forever. Probing one value per field is enough to reach
     every parse error, because the errors are about syntax and bounds. */
  parts.forEach((field, i) => fieldMatches(field, FIELDS[i].min, FIELDS[i].min, FIELDS[i].max, FIELDS[i].name));
  return { minute: parts[0], hour: parts[1], dom: parts[2], month: parts[3], dow: parts[4] };
}

/** Does this expression match this local wall-clock time? */
export function matchesLocal(expr, local) {
  const f = parseCron(expr);
  const minOk = fieldMatches(f.minute, local.minute, 0, 59, "minute");
  const hourOk = fieldMatches(f.hour, local.hour, 0, 23, "hour");
  const monthOk = fieldMatches(f.month, local.month, 1, 12, "month");
  if (!(minOk && hourOk && monthOk)) return false;

  const domOk = fieldMatches(f.dom, local.day, 1, 31, "day-of-month");
  const dowOk = fieldMatches(f.dow, local.dow, 0, 7, "day-of-week")
    || (local.dow === 0 && fieldMatches(f.dow, 7, 0, 7, "day-of-week"));

  /* Vixie's rule, reproduced rather than corrected. */
  if (f.dom !== "*" && f.dow !== "*") return domOk || dowOk;
  return domOk && dowOk;
}

// A star (with or without a step) in the hour field is a poll; anything else
// is an appointment. The engine uses this to decide DST behaviour.
export const isWallClock = (expr) => !/^\*/.test(String(expr).trim().split(/\s+/)[1] || "");

/* ── zone arithmetic, with no library ─────────────────────────────── */

const PARTS = new Map();
function formatter(tz) {
  if (!PARTS.has(tz)) {
    PARTS.set(tz, new Intl.DateTimeFormat("en-GB", {
      timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit",
      day: "2-digit", hour: "2-digit", minute: "2-digit", weekday: "short",
    }));
  }
  return PARTS.get(tz);
}
const DOW = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

/** The local wall clock in `tz` at an instant. */
export function localAt(instant, tz) {
  const p = formatter(tz).formatToParts(new Date(instant));
  const get = (k) => p.find((x) => x.type === k).value;
  return {
    year: +get("year"), month: +get("month"), day: +get("day"),
    hour: +get("hour"), minute: +get("minute"), dow: DOW[get("weekday")],
  };
}

const zoneOffset = (instant, tz) => {
  const l = localAt(instant, tz);
  return Date.UTC(l.year, l.month - 1, l.day, l.hour, l.minute) - Math.floor(instant / 60000) * 60000;
};

/** A local wall-clock minute back to an instant, or the reason there isn't one.
 *
 * Twice a year a local minute is not a time: it is skipped, or it happens
 * twice. Both are reported rather than resolved, because the engine resolves
 * them and this is a preview of what the engine will do, not a second ruling. */
export function instantFor({ year, month, day, hour, minute }, tz) {
  const wall = Date.UTC(year, month - 1, day, hour, minute);
  let t = wall - zoneOffset(wall, tz);
  t = wall - zoneOffset(t, tz);
  const back = localAt(t, tz);
  if (back.year !== year || back.month !== month || back.day !== day
      || back.hour !== hour || back.minute !== minute) {
    return { instant: null, note: "skipped by a clock change" };
  }
  /* The same wall-clock minute an hour earlier is the same minute again: the
     clock went back over it. Whether that means one firing or two is the
     caller's question, because it depends on the expression. */
  const earlier = localAt(t - 3600000, tz);
  const ambiguous = earlier.hour === hour && earlier.minute === minute && earlier.day === day;
  return { instant: t, ambiguous, note: null };
}

/** The next `count` local minutes this expression matches, from `from`. */
export function nextFires(expr, tz, count = 3, from = Date.now()) {
  parseCron(expr);
  const out = [];
  const start = localAt(from + 60000, tz);
  let cursor = Date.UTC(start.year, start.month - 1, start.day);
  const LIMIT = 400;                       // days; a yearly schedule still lands
  for (let d = 0; d < LIMIT && out.length < count; d++) {
    const day = new Date(cursor + d * 86400000);
    const probe = {
      year: day.getUTCFullYear(), month: day.getUTCMonth() + 1,
      day: day.getUTCDate(), dow: day.getUTCDay(), hour: 0, minute: 0,
    };
    /* Skip the whole day unless the day fields can match, which is what keeps
       this cheap for `0 3 1 1 *` without a special case for it. */
    const f = parseCron(expr);
    const domOk = fieldMatches(f.dom, probe.day, 1, 31, "day-of-month");
    const dowOk = fieldMatches(f.dow, probe.dow, 0, 7, "day-of-week")
      || (probe.dow === 0 && fieldMatches(f.dow, 7, 0, 7, "day-of-week"));
    const dayOk = (f.dom !== "*" && f.dow !== "*") ? (domOk || dowOk) : (domOk && dowOk);
    if (!dayOk || !fieldMatches(f.month, probe.month, 1, 12, "month")) continue;

    for (let h = 0; h < 24 && out.length < count; h++) {
      if (!fieldMatches(f.hour, h, 0, 23, "hour")) continue;
      for (let m = 0; m < 60 && out.length < count; m++) {
        if (!fieldMatches(f.minute, m, 0, 59, "minute")) continue;
        const local = { ...probe, hour: h, minute: m };
        const { instant, ambiguous, note } = instantFor(local, tz);
        if (instant !== null && instant <= from) continue;
        /* An appointment names an hour and must happen once, so the engine
           picks one of the two. A poll rides through, which means it fires in
           both — saying "once" here would be the preview contradicting
           `workflow.cron_is_wall_clock`. */
        out.push({
          local, instant,
          note: note || (ambiguous
            ? (isWallClock(expr)
                ? "the clock goes back over this; the engine fires it once"
                : "the clock goes back over this hour; a poll fires in both")
            : null),
        });
      }
    }
  }
  return out;
}

/* ── the expression, in words ──────────────────────────────────────── */

const ORDINAL = (n) => {
  if (n % 100 >= 11 && n % 100 <= 13) return n + "th";
  return n + ({ 1: "st", 2: "nd", 3: "rd" }[n % 10] || "th");
};
const DAY_NAME = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
const MONTH_NAME = ["", "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"];
const list = (xs) => xs.length <= 1 ? (xs[0] || "")
  : xs.slice(0, -1).join(", ") + " and " + xs[xs.length - 1];

const values = (field, min, max) => {
  const out = [];
  for (let v = min; v <= max; v++) if (fieldMatches(field, v, min, max)) out.push(v);
  return out;
};
const stepOf = (field) => {
  const m = /^\*\/(\d+)$/.exec(field.trim());
  return m ? Number(m[1]) : null;
};
const pad = (n) => String(n).padStart(2, "0");

function timeOfDay(minute, hour) {
  const mStep = stepOf(minute);
  const hStep = stepOf(hour);
  if (hour === "*" && minute === "*") return "every minute";
  if (hour === "*" && mStep) return `every ${mStep} minutes`;
  if (hour === "*") {
    const mins = values(minute, 0, 59);
    return mins.length === 1 ? `at ${pad(mins[0])} past every hour`
      : `at ${list(mins.map(pad))} past every hour`;
  }
  const mins = values(minute, 0, 59);
  if (hStep) {
    return mins.length === 1
      ? `every ${hStep} hours at ${pad(mins[0])} past`
      : `every ${hStep} hours, at ${list(mins.map(pad))} past`;
  }
  const hours = values(hour, 0, 23);
  if (mins.length === 1 && hours.length <= 4) {
    return "at " + list(hours.map((h) => `${pad(h)}:${pad(mins[0])}`));
  }
  const first = pad(hours[0]);
  const last = pad(hours[hours.length - 1]);
  if (mins.length === 1 && mins[0] === 0) {
    return `every hour on the hour from ${first}:00 to ${last}:00`;
  }
  const span = `${first}:00 to ${last}:59`;
  return mins.length === 1
    ? `at ${pad(mins[0])} past each hour from ${span}`
    : `at ${list(mins.map(pad))} past each hour from ${span}`;
}

function daySelection(dom, month, dow) {
  const parts = [];
  const domRestricted = dom !== "*";
  const dowRestricted = dow !== "*";

  if (domRestricted) {
    const days = values(dom, 1, 31);
    parts.push(days.length > 8 ? `on ${days.length} days of the month`
      : "on the " + list(days.map(ORDINAL)));
  }
  if (dowRestricted) {
    const raw = values(dow, 0, 7);
    const names = [...new Set(raw.map((d) => DAY_NAME[d]))];
    const weekdays = names.length === 5 && !names.includes("Sunday") && !names.includes("Saturday");
    parts.push(weekdays ? "on weekdays" : "on " + list(names));
  }
  /* The OR is the whole reason this sentence is worth rendering. */
  const days = domRestricted && dowRestricted ? parts.join(" or ") : parts.join(" ");

  if (month !== "*") {
    const months = values(month, 1, 12).map((m) => MONTH_NAME[m]);
    return (days ? days + " " : "") + "in " + list(months);
  }
  return days || "every day";
}

/** A five-field expression as a sentence. Throws what the engine would throw. */
export function describeCron(expr, timezone) {
  const f = parseCron(expr);
  const sentence = `${timeOfDay(f.minute, f.hour)}, ${daySelection(f.dom, f.month, f.dow)}`;
  return timezone ? `${sentence} (${timezone})` : sentence;
}
