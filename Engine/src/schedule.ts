// When the engine sends the page to the app after changes (the "document" event in src/engine.ts).

/**
 * The event follows a change after `documentDelay`, pushed back by every further change (each event carries the whole
 * page), but goes out at most `documentMaxWait` after the first change it reports. Without that limit a collaborator
 * typing faster than one key per `documentDelay` held it back until they paused, and the app's copy, which paths and
 * adopting collaborators' changes rely on, grew stale meanwhile.
 *
 * The engine's page is never shown, and the system pauses it at times, timers and incoming changes alike (mostly up to
 * about 250 ms in the simulator, measured on November 1, 2026), so events come about 0.6 s apart while someone types,
 * at times more; the engine's own document stands still during such a pause too.
 */
export const documentDelay = 150;
export const documentMaxWait = 400;

export type Clock = { now(): number; setTimeout(run: () => void, ms: number): number; clearTimeout(id: number): void };

export class DocumentSchedule {
  private timer?: number;
  /** When the pending event goes out at the latest. */
  private due?: number;

  constructor(private readonly clock: Clock, private readonly send: () => void) {}

  /** After a change: `documentDelay` for one the editor made (typing, a collaborator's), 0 for one the app waits for. */
  change(delay: number) {
    const now = this.clock.now();
    this.due ??= now + documentMaxWait;
    // The timer can run late (see above): a change that finds the limit passed sends the event itself.
    if (now >= this.due) return this.fire();
    if (this.timer !== undefined) this.clock.clearTimeout(this.timer);
    this.timer = this.clock.setTimeout(() => this.fire(), Math.min(delay, this.due - now));
  }

  /** Drops the pending event: the app reads the page itself (`flush`), or the page closes. */
  cancel() {
    if (this.timer !== undefined) this.clock.clearTimeout(this.timer);
    this.timer = undefined;
    this.due = undefined;
  }

  private fire() {
    this.cancel();
    this.send();
  }
}
