# Results — where the crossover actually is

12-logical / 6-physical core Windows 11 box, machteld 0.3.0, width 12, 3 reps after a discarded
warm-up, median reported with the observed range. Every arm's output was compared item by item
against sequential; none disagreed. Predictions were written in [README](README.md) before any of
this was run.

## CPU-bound Tcl

| per item | A sequential | B1 child per item | B2 static chunks | C pool (`pmap`) |
|---|---|---|---|---|
| 0.5 ms × 1600 | 741 ms — 1.00× | 16998 ms — **0.04×** | 318 ms — **2.33×** | 452 ms — 1.64× |
| 2 ms × 500 | 920 ms — 1.00× | 5531 ms — 0.17× | 372 ms — 2.48× | 374 ms — 2.46× |
| 8 ms × 150 | 997 ms — 1.00× | 1852 ms — 0.54× | 378 ms — 2.64× | 376 ms — **2.65×** |
| 30 ms × 40 | 937 ms — 1.00× | 676 ms — 1.39× | 373 ms — 2.51× | 379 ms — 2.47× |

## Skew — same total work, a tenth of the items 10× the rest

| | A sequential | B2 static chunks | C pool |
|---|---|---|---|
| heavy items **scattered** | 833 / 740 ms | **2.29× / 2.30×** | 2.17× / 2.05× |
| heavy items **contiguous** | 946 / 905 ms | 1.52× / 1.50× | **2.37× / 2.18×** |

Two independent runs shown, because a third run taken while the box was busy gave arm A a 1118–2409
ms spread and made static chunking look like 0.98×. Noise on this machine can reach 2–3× on a
single measurement; that is why nothing here rests on one number.

## An external program per item — `findstr` over a source file, 150 items

| | | |
|---|---|---|
| A sequential | 2434 ms | 1.00× |
| B1 child per item (spawns `findstr` **directly**) | 938 ms | **2.60×** |
| C pool | 1039 ms | 2.34× |

## Scoring the predictions

**1. WRONG, and the docs were right.** I predicted the shipped "~26 ms crossover" was a
single-item statement that ignored overlap, and that spawn-per-item would beat sequential from
about 2.4 ms. Measured, B1 is *underwater until roughly 20–30 ms per item* — 0.04× at 0.5 ms,
0.54× at 8 ms, 1.39× at 30 ms. The docs' figure was well calibrated and my correction was wrong.

The reason is the one thing this benchmark taught that none of the arms were designed to show:
**process creation does not parallelise.** Serially, one `cmd /c exit` costs 17.1 ms and one
machteld child 44.5 ms (of which sourcing the benchmark script is 0.6 ms — it is machteld's own
start). At width 12 that should give ~270 spawns/second. Measured across three independent points
in the sweep it gives **~90 a second** — 1600 spawns in 17.0 s, 500 in 5.53 s, 150 in 1.85 s.
Concurrency buys about 4× on spawning, not 12×, so `spawn_cost / width` is simply the wrong model.

**2. HALF RIGHT.** C does beat sequential at every size measured, down to 0.5 ms items — the
direction was right. But it tops out at **2.5–2.65×**, not the 3.5× I predicted from earlier
CPU-bound measurements in this project.

**3. RIGHT, and by more than expected.** C's margin over B1 is largest at the smallest item and
shrinks as items grow: **41×** the throughput at 0.5 ms (1.64× against 0.04×), 1.8× at 30 ms.

**4. RIGHT — and this is the finding that constrains the pool's claim.** A chunked `child start`
matches or beats the pool at **every** size measured: 2.33× against 1.64× at 0.5 ms, and within
noise of it at 2, 8 and 30 ms. It pays the start cost twelve times in total and then has no
protocol at all, so on uniform work the pool's per-item round trip buys nothing.

**5. RIGHT ONLY WHEN THE SKEW CLUSTERS — and my first test of it was too weak to say anything.**
Scattering the heavy items at random over 500 items leaves ~42 per chunk, which self-averages:
every chunk drew about the same number of them and static chunking never met a straggler (2.29×
against the pool's 2.17×). Putting the same heavy items in one contiguous run — what a directory
listing or a sorted work list actually looks like — drops static chunking to **1.50×** while the
pool holds **2.2–2.4×**. Same total work, same arms; only the *arrangement* changed.

**6. RIGHT.** For an external program per item, B1 spawns `findstr` directly with no intermediate
process and no round trip, and wins: 2.60× against the pool's 2.34×.

## What this means for the pool

The shipped claim — the crossover for offering work to another process falls from 26 ms to about
1 ms — **holds against spawn-per-item**, which is the comparison it was making, and the gap at
small items is far larger than advertised (41×, not a few×).

It does **not** hold as a claim about throughput in general, and the docs should not be read that
way. Against a competent static partition the pool is not faster; on uniform work it is
occasionally slower. What it is actually worth:

- **Item costs you cannot predict or that arrive clustered.** 1.50× against 2.2–2.4× is the whole
  argument for a queue over a partition, and it is the only place here where the pool wins on time.
- **Not having to write the partition.** One call against thirty lines of chunking, index
  arithmetic and result reassembly — which is where the bugs would live.
- **Supervision.** Requeue on worker death, poison after `-maxtries`, errorcodes preserved across
  the boundary. Not measured here; measured in the suite, and no arm above has any of it.
- **A director that stays responsive.** B2's `child wait` blocks; the pool multiplexes with
  `chan event`, which is what a Tk tool needs.

And where the pool is the *wrong* tool: a single external program per item, where `child start`
spawns the real program directly — 2.60× against 2.34× — and every layer the pool adds is a layer
between the director and the thing actually doing the work.
