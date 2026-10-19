"""Chapter four: the best placement, by fewest loose ends.

    python placement.py                     one unseeded trial on the quiet location
    python placement.py --sample location   the busy location from chapters two and three
    python placement.py --trials 5          several trials with a summary of oracle calls
    python placement.py --budget 60         cap the Grover oracle calls
    python placement.py --check             one seeded trial; exit 1 unless a best placement is found

The score
---------
A booking has a loose end on a side when the neighbouring slot there is free
for both the provider and the sub-location: a scrap of free time left next to
the booking. Zero loose ends means the booking sits flush against existing
bookings or the edges of the day, which is what an "optimised" placement policy
wants. The quantum side minimises this score with the same loop as chapter
three; the classical side scores all N triples in a loop.

Why a quiet day
---------------
On a busy day most feasible bookings already sit snug, so the minimum is found
on the first try and nothing is learned. On the quiet sample only 2 of 45
feasible bookings have no loose ends, 22 have one and 21 float in free time, so
the search has to walk down through the scores before it can stop.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import Counter
from pathlib import Path

import needle_bridge as bridge

HERE = Path(__file__).resolve().parent


def load(sample: str) -> dict:
    """Reads samples/<sample>.json, the same file the C# host reads."""
    return json.loads((HERE / "samples" / f"{sample}.json").read_text(encoding="utf-8"))


def feasible(loc: dict, duration: int) -> list[tuple[int, int, int]]:
    found = []
    slots = len(loc["slots"])
    for p in range(len(loc["providers"])):
        for s in range(len(loc["subLocations"])):
            for t in range(slots):
                if loc["qualified"][p] and loc["suitable"][s] and t + duration <= slots and all(
                    loc["providerFree"][p][t + k] and loc["subLocationFree"][s][t + k] for k in range(duration)
                ):
                    found.append((p, s, t))
    return found


def loose_ends(loc: dict, duration: int, booking: tuple[int, int, int]) -> int:
    """The classical score: free-for-both neighbours before and after the booking."""
    p, s, t = booking
    pf, sf, slots = loc["providerFree"], loc["subLocationFree"], len(loc["slots"])
    ends = 0
    if t > 0 and pf[p][t - 1] and sf[s][t - 1]:
        ends += 1
    if t + duration < slots and pf[p][t + duration] and sf[s][t + duration]:
        ends += 1
    return ends


def decode(loc: dict, index: int) -> tuple[int, int, int]:
    p, s = len(loc["providers"]), len(loc["subLocations"])
    return index % p, (index // p) % s, index // (p * s)


def describe(loc: dict, booking: tuple[int, int, int]) -> str:
    p, s, t = booking
    return f"{loc['providers'][p]} {loc['subLocations'][s]} {loc['slots'][t]}"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sample", default="location-quiet", help="which samples/<name>.json to search (default location-quiet)")
    parser.add_argument("--duration", type=int, default=2)
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
    loc = load(args.sample)
    tables = (loc["providerFree"], loc["subLocationFree"], loc["qualified"], loc["suitable"], args.duration)
    total = len(loc["providers"]) * len(loc["subLocations"]) * len(loc["slots"])
    budget = args.budget if args.budget is not None else bridge.durr_hoyer_budget(root, total)
    trials = 1 if args.check else args.trials

    reference = feasible(loc, args.duration)
    print(f"{args.sample}: {len(loc['providers'])} providers x {len(loc['subLocations'])} sub-locations x "
          f"{len(loc['slots'])} slots = {total} states, service of {args.duration} slot(s)")
    if not reference:
        print("no feasible booking exists; nothing to place")
        return 0

    scores = {b: loose_ends(loc, args.duration, b) for b in reference}
    by_score = Counter(scores.values())
    best_score = min(scores.values())
    best_set = [b for b, c in scores.items() if c == best_score]
    print(f"{len(reference)} feasible bookings; loose ends: {by_score.get(0, 0)} with none, "
          f"{by_score.get(1, 0)} with one, {by_score.get(2, 0)} with two")
    print(f"classical scan: {total} checks; best placements ({best_score} loose end(s)): "
          + ", ".join(describe(loc, b) for b in best_set))

    # Cross-check the Q# score function against this file's, for every feasible booking.
    disagreements = [b for b in reference if bridge.loose_ends(root, loc["providerFree"], loc["subLocationFree"], args.duration, *b) != scores[b]]
    print(f"the Q# score agrees with the Python score on all {len(reference)} feasible bookings"
          if not disagreements else f"SCORE MISMATCH on {len(disagreements)} bookings")
    print(f"quantum budget: {budget} Grover oracle calls (candidate verification is additional work)")

    found_best = 0
    calls_used: list[int] = []
    for trial in range(1, trials + 1):
        seed = 42 if args.check else -1
        index, calls_at_best, calls, runs = bridge.best_placement(root, *tables, budget, seed)
        if index < 0:
            print(f"trial {trial}: found nothing within the budget ({calls} Grover calls, {runs} circuits and classical candidate verifications)")
            continue
        booking = decode(loc, index)
        score = loose_ends(loc, args.duration, booking)
        is_best = booking in best_set
        found_best += is_best
        calls_used.append(calls_at_best)
        verdict = "a best placement" if is_best else ("feasible but looser" if booking in scores else "NOT FEASIBLE")
        stop = "stopped early: nothing beats zero loose ends" if score == 0 and calls < budget else "ran the budget out"
        print(f"trial {trial}: {describe(loc, booking)} ({score} loose end(s)) found after {calls_at_best} Grover calls; "
              f"{verdict}; {calls} Grover calls plus {runs} classical candidate verifications ({runs} circuits), {stop}")

    if trials > 1 and calls_used:
        print(f"summary: {found_best}/{trials} trials found a best placement; Grover calls until the final best among trials returning a booking "
              f"min/median/max {min(calls_used)}/{statistics.median(calls_used):.0f}/{max(calls_used)}; "
              f"the classical scan is {total} checks every time")

    if args.check:
        ok = found_best == 1 and not disagreements
        print("\nCHECK PASSED: the seeded run found a best placement and the two score functions agree" if ok
              else "\nCHECK FAILED")
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
