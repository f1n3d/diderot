// Checks when the engine sends the page to the app after changes (src/schedule.ts), on a simulated clock: soon after a
// change, at most `documentMaxWait` after the first one while changes keep coming, also when timers run late as in the
// engine's page, which is never shown. Exits with 1 on any difference.
import { DocumentSchedule, documentDelay, documentMaxWait } from "../src/schedule";

let differences = 0;

function expect(name: string, want: unknown, have: unknown) {
  if (JSON.stringify(want) === JSON.stringify(have)) return;
  differences++;
  console.log(`✗ ${name}\n  want: ${JSON.stringify(want)}\n  have: ${JSON.stringify(have)}`);
}

/**
 * The times (ms) the event goes out, for changes at `changes` (made with `documentDelay`, or 0 for the app's own),
 * timers firing `late` ms after their time, and the pending event dropped at `cancels`; simulated in 1 ms steps.
 */
function events(changes: { at: number; delay?: number }[], options: { late?: number; cancels?: number[]; until?: number } = {}): number[] {
  let now = 0;
  let next = 1;
  const timers = new Map<number, { at: number; run: () => void }>();
  const sent: number[] = [];
  const schedule = new DocumentSchedule({
    now: () => now,
    setTimeout: (run, ms) => {
      timers.set(next, { at: now + ms + (options.late ?? 0), run });
      return next++;
    },
    clearTimeout: (id) => timers.delete(id),
  }, () => sent.push(now));
  const until = options.until ?? Math.max(...changes.map((change) => change.at)) + 1000;
  for (now = 0; now <= until; now++) {
    for (const change of changes) if (change.at === now) schedule.change(change.delay ?? documentDelay);
    if (options.cancels?.includes(now)) schedule.cancel();
    for (const [id, timer] of [...timers]) {
      if (timer.at > now) continue;
      timers.delete(id);
      timer.run();
    }
  }
  return sent;
}

/** A collaborator typing a key every `every` ms from `from` to `to`. */
const typing = (from: number, to: number, every: number) =>
  Array.from({ length: Math.floor((to - from) / every) + 1 }, (_, index) => ({ at: from + index * every }));
/** For each event, how long after the first change it reports it went out. */
const waits = (changes: { at: number }[], times: number[]) =>
  times.map((time, index) => time - changes.find((change) => change.at > (times[index - 1] ?? -1))!.at);

expect("one change", [documentDelay], events([{ at: 0 }]));
expect("changes in a row: one event after the last", [200 + documentDelay], events([{ at: 0 }, { at: 100 }, { at: 200 }]));
expect("the app's own change", [10], events([{ at: 10, delay: 0 }]));
expect("dropped when the page closes", [], events([{ at: 0 }], { cancels: [100] }));

// While someone types faster than one key per `documentDelay`, each event goes out `documentMaxWait` after the first
// key it reports, and one after their last key.
const keys = typing(0, 3000, 60);
const fast = events(keys);
expect("typing fast: events while typing", true, fast.length > 5 && waits(keys, fast).slice(0, -1).every((wait) => wait === documentMaxWait));
expect("typing fast: the event after the last key", 3000 + documentDelay, fast.at(-1));
// Timers 200 ms late, as measured in the engine's page: the first key that finds the limit passed sends the event.
const late = events(keys, { late: 200 });
expect("typing fast, timers late: events while typing", true,
  late.length > 5 && waits(keys, late).slice(0, -1).every((wait) => wait > documentMaxWait && wait <= documentMaxWait + 60));

console.log(differences ? `${differences} schedule difference(s)` : "Document events keep up with changes.");
process.exitCode = differences ? 1 : 0;
