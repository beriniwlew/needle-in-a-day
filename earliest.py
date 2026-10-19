"""Chapter three: the earliest feasible booking, by Dürr and Høyer's minimum finding.

    python earliest.py                 one unseeded trial on the sample location
    python earliest.py --trials 5      several trials, with a summary of oracle calls
    python earliest.py --budget 60     cap the oracle calls below the default cap
    python earliest.py --check         one seeded trial; exit 1 unless it finds the true earliest

What is being measured
----------------------
The quantum side reports the oracle calls (Grover iterations) spent when it
last improved its answer, and the calls and circuit runs spent in total before
the Grover-call budget ran out or slot 0 was found. Every circuit also requires
one classical candidate verification, reported separately. The gap between the
two call counts is the cost of not knowing when to stop. The classical side is
a loop over all N triples, one trivial check each. Both are
printed side by side, because the honest comparison is the point: the square
root in the quantum cost is real, and at N = 128 the constants still hand the
win to the loop.

Why ``--check`` uses a single seeded trial
------------------------------------------
This minimum-finding variant is probabilistic; its paper-inspired default
budget does not establish a success guarantee for this implementation. A fixed
seed makes one particular trial reproducible, so the check asserts a specific
known-good run rather than a probability.
"""

from __future__ import annotations

import argparse
import statistics
import sys
from pathlib import Path

import needle_bridge as bridge
from location import (
    PROVIDER_FREE, PROVIDERS, QUALIFIED, SLOTS, SUB_LOCATION_FREE, SUB_LOCATIONS, SUITABLE,
    decode, describe, feasible,
)

HERE = Path(__file__).resolve().parent


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--duration", type=int, default=2, help="service length in slots (default 2)")
    parser.add_argument("--trials", type=int, default=1)
    parser.add_argument("--budget", type=int, help="cap on Grover oracle calls (default: paper-inspired budget)")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)

    if args.check:
        mismatches = bridge.sample_mismatches(str(HERE))
        if mismatches:
            print("CHECK FAILED: standalone Q# samples differ from JSON")
            for mismatch in mismatches:
                print("  " + mismatch)
            return 1

    root = str(HERE)
    total = len(PROVIDERS) * len(SUB_LOCATIONS) * len(SLOTS)
    budget = args.budget if args.budget is not None else bridge.durr_hoyer_budget(root, total)
    trials = 1 if args.check else args.trials

    # The classical answer: every feasible booking, then the smallest slot.
    reference = feasible(args.duration)
    print(f"{len(PROVIDERS)} providers x {len(SUB_LOCATIONS)} sub-locations x {len(SLOTS)} slots = {total} states, "
          f"service of {args.duration} slot(s)")
    if not reference:
        print("no feasible booking exists; nothing to find")
        return 0
    earliest_slot = min(t for _, _, t in reference)
    at_earliest = [b for b in reference if b[2] == earliest_slot]
    print(f"classical scan: {total} checks; earliest feasible slot is {SLOTS[earliest_slot]}, "
          f"held by {', '.join(describe(b).replace('  ', ' ') for b in at_earliest)}")
    print(f"quantum budget: {budget} Grover oracle calls"
          + (" (paper-inspired default; no proved success bound for this variant)" if args.budget is None else ""))

    found_earliest = 0
    calls_used: list[int] = []
    for trial in range(1, trials + 1):
        seed = 42 if args.check else -1
        index, calls_at_best, calls, runs = bridge.earliest_booking(
            root, PROVIDER_FREE, SUB_LOCATION_FREE, QUALIFIED, SUITABLE, args.duration, budget, seed)
        if index < 0:
            print(f"trial {trial}: found nothing within the budget ({calls} Grover calls, {runs} circuits and classical candidate verifications)")
            continue
        calls_used.append(calls_at_best)
        booking = decode(index)
        is_earliest = booking in at_earliest
        found_earliest += is_earliest
        verdict = "the true earliest" if is_earliest else ("feasible but later" if booking in reference else "NOT FEASIBLE")
        print(f"trial {trial}: {describe(booking).replace('  ', ' ')} found after {calls_at_best} Grover calls; {verdict}; "
              f"{calls} Grover calls plus {runs} classical candidate verifications ({runs} circuits) before stopping")

    if trials > 1 and calls_used:
        print(f"summary: {found_earliest}/{trials} trials found the earliest; Grover calls until the final best among trials returning a booking "
              f"min/median/max {min(calls_used)}/{statistics.median(calls_used):.0f}/{max(calls_used)}; "
              f"the classical scan is {total} checks every time")

    if args.check:
        if found_earliest == 1:
            print("\nCHECK PASSED: the seeded run found the earliest feasible booking")
            return 0
        print("\nCHECK FAILED: the seeded run did not find the earliest feasible booking")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
