# Where the crossover actually is — four ways to run N items

The pool shipped with a claim attached: *the crossover for offering work to another process falls
from 26 ms per item to about 1 ms.* That follows arithmetically from a 159 µs round trip against a
26 ms spawn, and arithmetic is not a measurement. Worse, the number it is compared against —
**"below roughly 25–30 ms of work per item, spawning costs more than it saves"** — is a
*single-item* statement, and nobody parallelises one item. Spawns overlap too.

This measures it, and measures the pool against the thing a competent person would actually write
instead.

## The four arms

Every arm runs the **same proc** over the same items, so the only variable is where it runs. (The
work is in a proc in all four: a hot loop at top level runs 3.6× slower, which is how an earlier
benchmark in this project reported parallelism as a *slowdown*.)

| | |
|---|---|
| **A — sequential** | `lmap` in the director. The baseline. |
| **B1 — child per item** | `child start` per item, bounded to width, `wait -any` to refill. The obvious old way. |
| **B2 — static chunks** | one child per worker, each handed a contiguous slice. The *smart* old way, and the pool's real competitor. |
| **C — pool** | `pmap` over persistent workers. |

Two workloads. **CPU-bound Tcl** at four item sizes (~0.5, 2, 8, 30 ms), which is what the
crossover claim is about; and **an external program per item** (`findstr` over a source file),
which is the archetype machteld exists for and the one case where B1 spawns the *real* program
directly and pays no intermediate Tcl process at all.

Plus a **skew** run: same total work, but a tenth of the items cost 10× the rest. Static chunking
should hate that; a queue should not notice.

## Predictions, registered before the run

Written down first because a benchmark you interpret after seeing it is a benchmark that agrees
with you. This project shipped a 38× speedup two hours ago that was a cold file cache.

1. **The 26 ms crossover is wrong as stated, and B1 is better than the docs imply.** Spawns overlap
   at width 12, so B1 beats sequential once *item > (item + 26)/12*, i.e. from about **2.4 ms** per
   item — not 26. I expect B1 to lose at 0.5 ms, roughly break even at 2 ms, and win from 8 ms up.
2. **C beats sequential from about 0.2 ms** and reaches ~3.5× — the ceiling every CPU-bound
   measurement on this 12-logical / 6-physical box has reached.
3. **C's margin over B1 is largest at the smallest item and vanishes as items grow.** At 0.5 ms I
   expect roughly 3× against something *below* 1×; at 30 ms I expect them within ~20% of each other.
4. **B2 will be competitive with C on uniform work — possibly better**, since it pays 26 ms twelve
   times in total and then has no protocol at all. If so, that is the honest finding and it goes in
   the docs: for uniform, coarse work a chunked `child start` is not worse.
5. **Under skew, B2 collapses and C does not.** This is the one where the queue earns its keep.
6. **For the external program, B1 ≈ C, and B1 may be slightly faster.** Both spawn one program per
   item; C adds a round trip and an intermediate process to do it. I do not expect the pool to win
   this on speed, and if it appears to, I will suspect the measurement before believing it.

If 4 and 6 come out as predicted, then the pool's value is *not* raw speed over a competent
`child start` — it is small items, skew, supervision, and one call instead of thirty lines. That
would be a narrower claim than the shipped docs make, and the docs would have to say so.

## Method

- Both halves of every comparison run **warm**: a discarded pass first. A cold pass measures the
  disk and the antivirus filter, not the design.
- **3 repetitions**, median reported, spread shown. One run is an anecdote.
- **Every arm's results are compared to arm A's**, item by item. An arm that disagrees is void,
  not fast.
- Item costs are a **fixed iteration count**, not a target time, so all four arms do byte-identical
  work rather than each arm's idea of "5 ms".

Results: [RESULTS.md](RESULTS.md).
