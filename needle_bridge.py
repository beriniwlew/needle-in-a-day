"""Typed bridge between any host language and the Q# project in this folder.

Why this file exists
--------------------
The Q# compiler and its simulator ship as a Python package (``qdk``); there is
no .NET API for them any more. Two very different hosts want to call the same
Q# operations:

* the four chapter scripts, plain Python hosts, and
* the C# console project under ``dotnet/``, which embeds a Python interpreter
  through CSnakes and calls into this module.

CSnakes reads the *type hints* of the top-level functions below when the C#
project is built and generates a C# class with one method per function. It
converts arguments and results between the two type systems: ``list[list[bool]]``
becomes ``IReadOnlyList<IReadOnlyList<bool>>``, ``int`` becomes ``long``,
``float`` becomes ``double``, ``list[int]`` becomes ``IReadOnlyList<long>``.
Keeping the hints simple and complete is therefore part of this module's
contract, which is why there are no dataclasses or fancy types here.

Design notes
------------
* Every function takes ``project_root``, the folder that holds ``qsharp.json``,
  so the module never has to guess where it was imported from. The Python
  scripts pass their own folder; the C# host walks up from its binary.
* ``qdk.init`` compiles the whole Q# project (every ``.qs`` file under ``src``).
  It takes a fraction of a second, which is still worth doing once, so
  ``init`` remembers which root it loaded and skips repeat calls.
* ``qsharp.run(callable, shots, *args, seed=...)`` runs a Q# operation
  ``shots`` times on the sparse-state simulator, with the Python arguments
  converted to Q# values (``list[bool]`` to ``Bool[]``, nested lists to
  ``Bool[][]``), and returns one Python value per shot: the operation's return
  value, so an ``Int`` arrives as an ``int``.
* Seeds: a negative seed means "unseeded". CSnakes handles ``int | None`` too,
  but a plain ``int`` keeps the generated C# signature a single overload.
"""

from __future__ import annotations

import json
from pathlib import Path

import qdk
import qdk.code
from qdk import qsharp

# The project root whose Q# is currently compiled into the interpreter, or None
# before the first call. Module-level state is deliberate: both hosts call
# several functions in a row and should pay for compilation only once.
_loaded_root: str | None = None


def init(project_root: str) -> None:
    """Compile the Q# project under ``project_root`` once; later calls are no-ops.

    ``qdk.init`` replaces the interpreter's whole Q# context, so switching roots
    recompiles. Nothing in this project ever does that; the guard is a courtesy.
    """
    global _loaded_root
    if _loaded_root != project_root:
        qdk.init(project_root=project_root)
        _loaded_root = project_root


def search_day(project_root: str, free: list[bool], shots: int, seed: int = -1) -> list[int]:
    """Chapter one: run ``SlotSearch.FindFreeSlot`` ``shots`` times.

    ``free`` has one entry per candidate start time and its length must be a
    power of two. Each returned value is the slot index one run measured; the
    histogram of these values is what the hosts print. With M free slots out of
    N the share of correct answers is about sin²((2k+1)θ), sin²θ = M/N.
    """
    init(project_root)
    results = qsharp.run(qdk.code.SlotSearch.FindFreeSlot, shots, free, seed=_seed(seed))
    return [int(r) for r in results]


def sample_mismatches(project_root: str) -> list[str]:
    """Compare the standalone Q# examples' actual inputs with samples/*.json.

    Comparing every cell and flag catches changes that leave feasible counts
    unchanged. Labels are host-only data and are not mirrored in Q#.
    """
    init(project_root)
    samples = Path(project_root) / "samples"
    problems: list[str] = []
    days = json.loads((samples / "days.json").read_text(encoding="utf-8"))
    mirrored_days = [day["free"] for day in days["days"] if day["name"] == "three openings"]
    if mirrored_days != [qdk.code.Samples.DayFree()]:
        problems.append("samples/days.json: three openings differs from Samples.DayFree()")

    for name, tables in (
        ("location", qdk.code.Samples.BusyLocationTables()),
        ("location-quiet", qdk.code.Samples.QuietLocationTables()),
    ):
        sample = json.loads((samples / f"{name}.json").read_text(encoding="utf-8"))
        for key, actual in zip(("providerFree", "subLocationFree", "qualified", "suitable"), tables):
            if sample[key] != actual:
                problems.append(f"samples/{name}.json: {key} differs from the Q# sample")
    return problems


def feasible_count(
    project_root: str,
    provider_free: list[list[bool]],
    sub_location_free: list[list[bool]],
    qualified: list[bool],
    suitable: list[bool],
    duration_slots: int,
) -> int:
    """Chapter two: the number of feasible bookings, counted by the Q# function.

    This is a classical brute-force loop that happens to be written in Q#. The
    hosts call it to cross-check their own loops and to show that the
    iteration count the search uses depends on knowing this number.
    """
    init(project_root)
    return int(qdk.code.LocationSearch.FeasibleCount(provider_free, sub_location_free, qualified, suitable, duration_slots))


def search_bookings(
    project_root: str,
    provider_free: list[list[bool]],
    sub_location_free: list[list[bool]],
    qualified: list[bool],
    suitable: list[bool],
    duration_slots: int,
    shots: int,
    seed: int = -1,
) -> list[int]:
    """Chapter two: run ``LocationSearch.FindBooking`` ``shots`` times.

    Tables are rows of slots: ``provider_free[p][t]`` and ``sub_location_free[r][t]``.
    ``qualified[p]`` says whether provider p offers the service and
    ``suitable[r]`` whether sub-location r can host it; ``duration_slots`` is how many
    consecutive slots the service occupies.

    Each returned value is one measured register, packed as p + P*s + P*S*t
    with P providers and S sub-locations, exactly the little-endian layout of the
    Q# register. Decode with ``p = v % P``, ``s = (v // P) % S``,
    ``t = v // (P * S)``; both hosts have a helper that does this.
    """
    init(project_root)
    results = qsharp.run(
        qdk.code.LocationSearch.FindBooking, shots,
        provider_free, sub_location_free, qualified, suitable, duration_slots,
        seed=_seed(seed),
    )
    return [int(r) for r in results]


def earliest_booking(
    project_root: str,
    provider_free: list[list[bool]],
    sub_location_free: list[list[bool]],
    qualified: list[bool],
    suitable: list[bool],
    duration_slots: int,
    budget: int,
    seed: int = -1,
) -> tuple[int, int, int, int]:
    """Chapter three: run ``EarliestSearch.EarliestBooking`` once.

    Returns ``(index, calls_at_best, calls, runs)``: the combined index of the
    earliest feasible booking found (-1 if none), the oracle calls spent when that
    best was found, the oracle calls spent in total, and the number of circuits
    run and measured. ``budget`` caps only Grover oracle calls. ``runs`` also
    counts candidate verifications, one per circuit, which are additional
    classical work. Budget zero permits one uniform sample and verification.
    ``durr_hoyer_budget`` gives a paper-inspired default, not a proven success
    bound for this variant.

    The algorithm draws random iteration counts in Q#, so a reproducible run
    needs the classical random source seeded as well as the measurements. Both
    are seeded here from the one ``seed`` value; a negative seed leaves both
    unseeded.
    """
    init(project_root)
    qsharp.set_classical_seed(_seed(seed))
    results = qsharp.run(
        qdk.code.EarliestSearch.EarliestBooking, 1,
        provider_free, sub_location_free, qualified, suitable, duration_slots, budget,
        seed=_seed(seed),
    )
    index, calls_at_best, calls, runs = results[0]
    return int(index), int(calls_at_best), int(calls), int(runs)


def durr_hoyer_budget(project_root: str, total: int) -> int:
    """Paper-inspired demonstration cap ceil(22.5·√N + 1.4·lg²N), not a success guarantee."""
    init(project_root)
    return int(qdk.code.EarliestSearch.DurrHoyerBudget(total))


def best_placement(
    project_root: str,
    provider_free: list[list[bool]],
    sub_location_free: list[list[bool]],
    qualified: list[bool],
    suitable: list[bool],
    duration_slots: int,
    budget: int,
    seed: int = -1,
) -> tuple[int, int, int, int]:
    """Chapter four: run ``PlacementSearch.BestPlacement`` once.

    Same contract as ``earliest_booking``: ``(index, calls_at_best, calls, runs)``
    for the feasible booking with the fewest loose ends. The total is usually
    far below the budget, because a booking with no loose ends ends the search.
    """
    init(project_root)
    qsharp.set_classical_seed(_seed(seed))
    results = qsharp.run(
        qdk.code.PlacementSearch.BestPlacement, 1,
        provider_free, sub_location_free, qualified, suitable, duration_slots, budget,
        seed=_seed(seed),
    )
    index, calls_at_best, calls, runs = results[0]
    return int(index), int(calls_at_best), int(calls), int(runs)


def loose_ends(
    project_root: str,
    provider_free: list[list[bool]],
    sub_location_free: list[list[bool]],
    duration_slots: int,
    provider: int,
    sub_location: int,
    slot: int,
) -> int:
    """The Q# version of the chapter-four score, so hosts can check it against their own."""
    init(project_root)
    return int(qdk.code.PlacementSearch.LooseEnds(provider_free, sub_location_free, duration_slots, provider, sub_location, slot))


def grover_iterations(project_root: str, total: int, marked: int) -> int:
    """Choose the better integer count around the first Grover peak; prefer fewer rounds on ties."""
    init(project_root)
    return int(qdk.code.SlotSearch.GroverIterations(total, marked))


def success_probability(project_root: str, total: int, marked: int) -> float:
    """sin²((2k+1)θ) with sin²θ = marked/total: the chance one run returns a marked state."""
    init(project_root)
    return float(qdk.code.SlotSearch.SuccessProbability(total, marked))


def _seed(seed: int) -> int | None:
    """Translate the hosts' "negative means none" convention into the simulator's ``None``."""
    return None if seed < 0 else seed


def release() -> None:
    """Drop the compiled Q# program on the calling thread, before an embedding host shuts Python down.

    ``qdk.init`` fills the ``qdk.code`` namespace with one handle per Q# callable
    in this project. Those handles are not thread-safe, and the Rust
    layer underneath prints a ``RuntimeError: ... is being dropped on another
    thread`` for each one if interpreter shutdown happens to run on a different
    thread, which is what an embedding host like CSnakes does. Re-initialising
    with no project replaces the handles with nothing, here, on the thread that
    created them, so the shutdown stays quiet. Plain Python scripts never need
    this: CPython tears itself down on the thread that built everything.
    """
    global _loaded_root
    qdk.init()
    _loaded_root = None
