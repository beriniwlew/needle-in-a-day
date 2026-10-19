"""Chapter one: Grover's search over one provider's day, hosted from Python.

    python driver.py            histograms for the sample days
    python driver.py --check    seeded run; exit 1 if a hit rate falls short of theory
    python driver.py --circuit  also print the circuit for the three-opening day

How to read the output
----------------------
Each sample day is a row of eight booleans, one per hourly start from 09:00.
The search runs ``shots`` times; each run collapses to one slot index. The
histogram shows how often each slot came out. A good run piles the counts on
the FREE rows and leaves the busy rows with a few percent each. Grover's search
is probabilistic: it raises the odds of a right answer, it never guarantees one,
so a busy slot appearing a handful of times is expected, not a bug.

Why ``--check`` tolerates ten points
------------------------------------
With 400 shots and a success probability near 90%, the binomial noise is about
1.5 points, so a seeded run that lands more than ten points under theory means
the circuit is wrong, not unlucky. The seed makes the check reproducible.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

import qdk.code
from qdk import qsharp

import needle_bridge as bridge

# The folder holding qsharp.json. The bridge compiles the Q# found under it.
HERE = Path(__file__).resolve().parent

# The sample days live in samples/days.json, shared with the C# host's --day
# mode. Slot 0 starts at dayStartHour and each slot is one hour; the labels are
# cosmetic, the search only ever sees indices. "fully booked" exists to show
# what Grover's search cannot do.
DAYS_FILE = json.loads((HERE / "samples" / "days.json").read_text(encoding="utf-8"))
DAY_START_HOUR: int = DAYS_FILE["dayStartHour"]
SAMPLE_DAYS: dict[str, list[bool]] = {day["name"]: day["free"] for day in DAYS_FILE["days"]}


def slot_label(index: int) -> str:
    return f"{DAY_START_HOUR + index:02d}:00"


def free_indices(free: list[bool]) -> list[int]:
    """The classical answer: a linear scan over eight booleans, done in nanoseconds."""
    return [i for i, is_free in enumerate(free) if is_free]


def run_day(name: str, free: list[bool], shots: int, seed: int) -> tuple[float, float] | None:
    """Search one day, print its histogram, return (measured hit rate, theoretical rate)."""
    marked = free_indices(free)
    print(f"\n{name}: {len(marked)} of {len(free)} slots free")

    if not marked:
        # The oracle flips the sign of marked states. With none marked it is the
        # identity, the diffusion step has nothing to amplify, and a measurement
        # is a uniformly random slot. The host must answer this case itself.
        print("  Nothing to find. Grover's search amplifies marked states; with none marked it")
        print("  returns a uniformly random slot, so the host answers this one classically: none.")
        return None

    root = str(HERE)
    total, count = len(free), len(marked)
    iterations = bridge.grover_iterations(root, total, count)
    theory = bridge.success_probability(root, total, count)

    # One quantum run per shot. The Python list of booleans crosses into Q# as
    # Bool[]; each shot hands back the Int the operation returned.
    results = bridge.search_day(root, free, shots, seed)
    counts = Counter(results)
    hits = sum(counts[i] for i in marked)
    rate = hits / shots

    print(f"  {iterations} Grover iteration(s), {shots} shots")
    for i in range(total):
        bar = "#" * round(40 * counts[i] / shots)
        print(f"  {slot_label(i)}  {'FREE' if free[i] else 'busy'}  {counts[i]:5d}  {bar}")
    print(f"  measured a free slot {rate:.1%} of the time; theory says {theory:.1%}")
    print(f"  classical scan: {', '.join(slot_label(i) for i in marked)}")
    return rate, theory


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--shots", type=int, default=200)
    parser.add_argument("--check", action="store_true", help="seeded run that fails if results fall short of theory")
    parser.add_argument("--circuit", action="store_true", help="print the circuit for the three-opening day")
    args = parser.parse_args(argv)

    if args.check:
        mismatches = bridge.sample_mismatches(str(HERE))
        if mismatches:
            print("CHECK FAILED: standalone Q# samples differ from JSON")
            for mismatch in mismatches:
                print("  " + mismatch)
            return 1

    # A fixed seed makes the simulator's measurement outcomes reproducible, so
    # the check is deterministic. Unseeded runs vary a little between runs,
    # which is the honest face of a probabilistic algorithm.
    seed = 42 if args.check else -1
    shots = max(args.shots, 400) if args.check else args.shots
    shortfalls: list[str] = []

    for name, free in SAMPLE_DAYS.items():
        outcome = run_day(name, free, shots, seed)
        if outcome is None:
            continue
        rate, theory = outcome
        if args.check and rate < theory - 0.10:
            shortfalls.append(f"{name}: measured {rate:.1%}, theory {theory:.1%}")

    if args.circuit:
        # The renderer traces the operation's gates for the given arguments. It
        # cannot follow classical decisions made on measurement results, which
        # is why GroverSearch returns raw results and FindFreeSlot converts them
        # outside the drawn part.
        bridge.init(str(HERE))
        print("\ncircuit for the three-opening day (GroverSearch, the quantum part before the host turns results into an index):")
        print(qsharp.circuit(qdk.code.SlotSearch.GroverSearch, SAMPLE_DAYS["three openings"]))

    if args.check:
        if shortfalls:
            print("\nCHECK FAILED")
            for line in shortfalls:
                print("  " + line)
            return 1
        print("\nCHECK PASSED: every sample day measured within 10 points of theory")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
