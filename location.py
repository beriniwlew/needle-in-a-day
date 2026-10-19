"""Chapter two: Grover's search over provider × sub-location × time, hosted from Python.

    python location.py                  histogram for the sample location, two-slot service
    python location.py --duration 1     one-slot service
    python location.py --check          seeded run; exit 1 if results fall short of theory

The location
----------
Four providers, four sub-locations, eight hourly slots from 09:00: 4 × 4 × 8 = 128
possible bookings, named by 2 + 2 + 3 = 7 qubits. Two availability tables say
who and which sub-location is free in each slot; two flag lists say who may perform the
service and which sub-locations suit it. Casey is not qualified and Suite D lacks the
equipment, so neither can be part of a feasible booking, however free they are.

What the search returns
-----------------------
Each run measures the whole seven-qubit register as one integer packed as
p + 4·s + 16·t. ``decode`` unpacks it. A feasible booking should dominate the
histogram; the few infeasible outcomes that appear are the residual probability
Grover's search leaves on the wrong states, not errors.

The classical loop next to it
-----------------------------
``feasible`` is the brute-force answer and runs in microseconds. It is printed
for comparison, and its count is also what the Q# code needs to choose the
number of Grover iterations, a shortcut the README discusses.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

import needle_bridge as bridge

HERE = Path(__file__).resolve().parent

# The sample location lives in samples/location.json, shared with the C# host.
# One availability row per provider and per sub-location, one entry per slot,
# True meaning free; one flag per provider (qualified) and per sub-location
# (suitable). src/Samples.qs mirrors the same data by hand for running the Q#
# alone, and --check compares every mirrored cell and flag. The busy day has 26 feasible one-slot bookings
# and 10 two-slot ones.
SAMPLE = json.loads((HERE / "samples" / "location.json").read_text(encoding="utf-8"))
PROVIDERS: list[str] = SAMPLE["providers"]
SUB_LOCATIONS: list[str] = SAMPLE["subLocations"]
SLOTS: list[str] = SAMPLE["slots"]
PROVIDER_FREE: list[list[bool]] = SAMPLE["providerFree"]
SUB_LOCATION_FREE: list[list[bool]] = SAMPLE["subLocationFree"]
QUALIFIED: list[bool] = SAMPLE["qualified"]
SUITABLE: list[bool] = SAMPLE["suitable"]


def decode(index: int) -> tuple[int, int, int]:
    """Unpack p + P·s + P·S·t: provider is the low "digit", then sub-location, then slot."""
    p, s = len(PROVIDERS), len(SUB_LOCATIONS)
    return index % p, (index // p) % s, index // (p * s)


def describe(booking: tuple[int, int, int]) -> str:
    p, s, t = booking
    return f"{PROVIDERS[p]:6s} {SUB_LOCATIONS[s]}  {SLOTS[t]}"


def feasible(duration: int) -> list[tuple[int, int, int]]:
    """The classical answer: a triple loop applying the same check the oracle computes.

    A booking is feasible when the provider is qualified, the sub-location is
    suitable, the service ends inside the day, and both the provider and
    the sub-location are free in every slot the service covers.
    """
    found = []
    for p in range(len(PROVIDERS)):
        for s in range(len(SUB_LOCATIONS)):
            for t in range(len(SLOTS)):
                fits = t + duration <= len(SLOTS)
                if QUALIFIED[p] and SUITABLE[s] and fits and all(
                    PROVIDER_FREE[p][t + k] and SUB_LOCATION_FREE[s][t + k] for k in range(duration)
                ):
                    found.append((p, s, t))
    return found


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--duration", type=int, default=2, help="service length in slots (default 2)")
    parser.add_argument("--shots", type=int, default=200)
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
    seed = 42 if args.check else -1
    shots = max(args.shots, 400) if args.check else args.shots
    total = len(PROVIDERS) * len(SUB_LOCATIONS) * len(SLOTS)

    # Two independent counts of the feasible bookings: this file's loop and the
    # Q# function. They must agree, or the oracle and the reference disagree
    # about what "feasible" means.
    reference = feasible(args.duration)
    marked = bridge.feasible_count(root, PROVIDER_FREE, SUB_LOCATION_FREE, QUALIFIED, SUITABLE, args.duration)

    print(f"{len(PROVIDERS)} providers x {len(SUB_LOCATIONS)} sub-locations x {len(SLOTS)} slots = {total} states, "
          f"service of {args.duration} slot(s)")
    print(f"classical loop finds {len(reference)} feasible bookings; the Q# count says {marked}")
    if args.check and marked != len(reference):
        print("CHECK FAILED: the Q# count differs from the classical loop")
        return 1
    if marked == 0:
        print("nothing to search for")
        return 0

    iterations = bridge.grover_iterations(root, total, marked)
    theory = bridge.success_probability(root, total, marked)
    results = bridge.search_bookings(root, PROVIDER_FREE, SUB_LOCATION_FREE, QUALIFIED, SUITABLE,
                                     args.duration, shots, seed)
    counts = Counter(decode(i) for i in results)
    feasible_set = set(reference)
    hits = sum(n for b, n in counts.items() if b in feasible_set)
    rate = hits / shots

    print(f"{iterations} Grover iteration(s), {shots} shots; outcomes seen, most frequent first:")
    for booking, n in counts.most_common(14):
        tag = "FEASIBLE  " if booking in feasible_set else "infeasible"
        print(f"  {describe(booking)}  {tag} {n:5d}  {'#' * round(40 * n / shots)}")
    if len(counts) > 14:
        print(f"  ... and {len(counts) - 14} more outcomes")
    print(f"measured a feasible booking {rate:.1%} of the time; theory says {theory:.1%}")
    print("classical reference: " + ", ".join(describe(b).replace("  ", " ") for b in reference))

    if args.check:
        problems = []
        if marked != len(reference):
            problems.append(f"Q# count {marked} differs from the classical loop {len(reference)}")
        if rate < theory - 0.10:
            problems.append(f"measured {rate:.1%}, theory {theory:.1%}")
        if problems:
            print("\nCHECK FAILED")
            for line in problems:
                print("  " + line)
            return 1
        print("\nCHECK PASSED: counts agree and the hit rate is within 10 points of theory")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
