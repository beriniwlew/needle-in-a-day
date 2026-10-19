# Needle in a day: learn Grover's search with appointment slots

A small quantum computing project for programmers who know functions, arrays,
and loops. No physics background is assumed. Four chapters turn a search for
an available appointment into a search for the earliest or best-fitting booking.
Each meaningful step in the Q# source is explained alongside the code.

Everything runs on a classical simulator. Python and C# hosts drive the same
Q# circuits, with ordinary loops beside them to check the answers. At this
scale the classical solution is faster; the point is to learn how the quantum
algorithm works and what work it actually performs.

## Get your first result

Install [uv](https://docs.astral.sh/uv/). The project declares Python 3.10 or
newer and selects Python 3.14 in [.python-version](.python-version); uv can
provision that interpreter. The C# path additionally needs the .NET 10 SDK.
Rider and VS Code are optional. No quantum hardware or cloud account is needed.

```bash
git clone https://github.com/beriniwlew/needle-in-a-day.git
cd needle-in-a-day
uv sync
uv run driver.py --check
```

`uv sync` creates `.venv` and installs the dependencies from `uv.lock`. The
check runs the first chapter with a fixed random seed and ends with
`CHECK PASSED`. If you already have the project, start with `uv sync` in its
root folder. Without uv, install `requirements.txt` in a Python virtual
environment and use `python` in place of `uv run` in the commands below.

### Read the output

Selected lines from the three-openings day in the seeded check:

```text
three openings: 3 of 8 slots free
  1 Grover iteration(s), 400 shots
  measured a free slot 84.8% of the time; theory says 84.4%
  classical scan: 11:00, 13:00, 16:00
```

- A **shot** is one fresh preparation, circuit execution, and measurement. Here
  the program samples 400 slot indices; the histogram counts each outcome.
- A **Grover iteration** applies the marking oracle once, then a diffusion step.
  It is one round inside a shot, not another shot.
- The **hit rate**, 84.8%, is the share of measured indices that name free slots.
  The remaining results are busy slots: the algorithm improves the probability
  of success but does not generally make it 100%.
- **Theory**, 84.4%, is the probability calculated for this circuit. Finite
  samples fluctuate around it. Unseeded runs vary; exact seeded outcomes can
  change when the simulator version changes.
- The **classical scan** reads the flags directly and lists the correct answers.
  It is the reference used to judge the circuit's output.

The fully booked example is handled classically: there is no answer to amplify.
The `--check` mode uses at least 400 shots and fails if the hit rate is more than
10 percentage points below theory. It also checks that the standalone Q# sample
inputs match the JSON files. These are reproducible regression checks, not a
proof of a general success probability.

## Choose a chapter

Read them in order the first time. Start at `Samples.Main` in
[Samples.qs](src/Samples.qs), then follow its call into `SlotSearch.FindFreeSlot`.
The first Q# file contains the amplitude model and a syntax guide; later files
explain each new idea where it is used.

| Chapter | Question | New idea | Q# source | Run and check |
|---|---|---|---|---|
| 1 | Which start slot is free? | Phase marking and amplification | [SlotSearch.qs](src/SlotSearch.qs) | `uv run driver.py --check` |
| 2 | Which provider, room, and time work? | A computed constraint oracle | [LocationSearch.qs](src/LocationSearch.qs) | `uv run location.py --check` |
| 3 | What is the earliest feasible booking? | Threshold search with an unknown answer count | [EarliestSearch.qs](src/EarliestSearch.qs) | `uv run earliest.py --check` |
| 4 | Which placement leaves the fewest loose ends? | Computing and minimising a score | [PlacementSearch.qs](src/PlacementSearch.qs) | `uv run placement.py --check` |

For the implementation boundary between languages, see
[how the hosts call Q#](docs/architecture.md). For other entry points, jump to
[C# and editors](#run-with-c-or-an-editor) or [validation](#validate-the-project).

## Vocabulary

### The booking problem

| Term | Meaning here |
|---|---|
| Location | The whole place being booked, with one day of slots. |
| Sub-location | A bookable room or space; the samples call them Suite A to D. |
| Provider | The person who performs the service. |
| Slot | One indexed start time; sample slots are hourly, starting at 09:00. |
| Feasible booking | A qualified provider and suitable room, both free for the entire service within the day. |

### The quantum program

| Term | Programmer's reading |
|---|---|
| Qubit | A quantum bit; measurement in the basis used here returns 0 or 1. |
| Register | A group of qubits whose measured bits encode an index; n index qubits can name 2ⁿ candidates. |
| Amplitude | A number attached to a possible bit pattern; its squared magnitude gives that pattern's measurement probability. |
| Superposition | A state with nonzero amplitudes for several patterns; you can sample it but cannot read out every candidate. |
| Gate | A reversible transformation of amplitudes, such as a bit flip or a change of sign. |
| Oracle | A circuit that recognises candidates satisfying a condition; these search oracles mark them by changing their signs. |
| Phase flip | Negating an amplitude; its probability stays the same until later gates mix amplitudes. |
| Diffusion | The Grover step that mixes amplitudes after marking, changing the chances of measuring marked candidates. |
| Ancilla | A scratch qubit used to hold an intermediate condition. |
| Uncomputation | Reversing scratch calculations so the scratch qubits return to zero while the intended phase marks remain. |
| Measurement | Sampling a bit pattern and replacing the superposition with the observed state; another independent sample needs fresh preparation. |
| QROM | A lookup circuit built from a classical table; its gate cost grows with the data it loads. |

These circuits use real amplitudes, so the comments use signed numbers and
ordinary squares. General quantum amplitudes can be complex. The array analogy
explains the mathematics; it is not an array a hardware program can inspect.

## Chapter one: one provider's day

Eight start-slot flags need three index qubits. Each free flag becomes a phase
mark in the oracle. The diffusion step then changes the measurement odds.
[SlotSearch.qs](src/SlotSearch.qs) explains the gates, their effect on amplitudes,
and how many repetitions to choose.

The free slots are already supplied in the input, so constructing this oracle
requires reading the flags. This chapter makes the smallest circuit easy to
follow; it does not avoid the work of finding those flags. It searches allowed
start times without computing a service-duration constraint.

**Try changing the number of shots:**

```bash
uv run driver.py --shots 20
uv run driver.py --shots 400
uv run driver.py --circuit
```

Compare the measured rates with theory. Smaller samples generally fluctuate
more. Leave off `--check` for this experiment, since it enforces at least 400
shots and fixes the seed. `--circuit` draws the three-openings circuit.

## Chapter two: provider × sub-location × time

Four providers, four rooms, and eight slots give 128 candidates on seven index
qubits. The inputs stay separate: two availability tables, provider
qualifications, and room suitability. The oracle computes each condition into
scratch qubits and marks a booking only when every condition holds.

For a two-slot service, the circuit shifts the time register to read the next
slot, then restores it. A boundary flag rejects starts that would run past the
end of the day. The table lookups are QROM circuits, with one pattern-controlled
operation per true cell. Those operations decompose into gates and must also be
undone during uncomputation; loading data is part of the cost.

| Example | Duration constraint | Index qubits | Candidates | Marked candidates | Iterations | Theoretical hit rate |
|---|---|--:|--:|--:|--:|--:|
| Chapter 1: three-openings day | Supplied start flags only | 3 | 8 | 3 | 1 | 84.4% |
| Chapter 2: busy location | 1 slot | 7 | 128 | 26 | 1 | 97.2% |
| Chapter 2: busy location | 2 slots | 7 | 128 | 10 | 2 | 97.6% |

**Index qubits exclude scratch qubits.** The two-slot location oracle explicitly
allocates seven additional scratch qubits, and library gate decompositions may
need more. Casey is unqualified and Suite D lacks equipment, so neither belongs
to a feasible booking regardless of their availability.

**Try changing the duration:**

```bash
uv run location.py --duration 1 --check
uv run location.py --duration 2 --check
```

The reference count falls from 26 to 10: both resources must now be available
for two consecutive slots. Compare the Grover iteration counts as well.

## Chapter three: the earliest feasible booking

Hold a threshold slot, initially the end of the day. Search for a feasible
booking before it, verify the measured candidate classically, and lower the
threshold whenever a better booking appears. Stop at slot 0, which cannot be
beaten, or when the Grover-call budget runs out.

The number of bookings below the changing threshold is unknown. The
Boyer–Brassard–Høyer–Tapp schedule replaces a known answer count with a random
iteration count: start with a range of one, grow it by six fifths after a miss,
and cap it at √N. Chapters one and two instead count the marked candidates
classically before choosing their iterations.

The default cap is `ceil(22.5·√N + 1.4·lg²N)`, or 324 for the sample, inspired
by the [Dürr–Høyer paper](https://arxiv.org/pdf/quant-ph/9607014). The paper's
success guarantee uses its own algorithm and time model, including a random
initial threshold and initialisation work. This variant starts from a sentinel
and caps only Grover oracle calls; borrowing the formula does not establish
the same guarantee.

The seeded check finds Drew in Suite B at 10:00 after 19 Grover calls and
finishes after 324 calls plus 80 classical candidate verifications. Every
circuit needs one verification, even with zero Grover iterations. The counts
exclude state preparation and the gates inside each oracle; they are not
elapsed time. The classical reference checks 128 candidates.

**Try reducing the budget:**

```bash
uv run earliest.py --budget 20 --trials 10
uv run earliest.py --budget 324 --trials 10
```

Compare how often the true earliest is found, and the work spent when the best
answer appeared versus when the search stopped. A larger budget allows more
searching but does not guarantee a better result in an individual random trial.
`--budget 0` deliberately allows one uniform sample and its verification.

## Chapter four: the best placement, by fewest loose ends

A booking has a loose end on a side when the neighbouring slot is free for both
the provider and room. Zero loose ends means it sits against existing bookings
or the day boundary; two means it floats in free time. This discrete score
illustrates a placement policy, without modelling buffers or continuous time.

The circuit reads the neighbours by shifting time by −1 and by the service
duration, with boundary flags to reject wrapped-around reads. It compares the
score using two flags: below 3 is always true, below 2 means not both open, and
below 1 means neither open. Their sum is the score; they are not a binary
encoding of it. Setup and uncomputation also cost gates.

The same threshold-search loop now seeks a smaller score. A verified score of
zero ends the search immediately. On the quiet sample, 45 bookings are feasible:
2 have zero loose ends, 22 have one, and 21 have two. The seeded run finds Blake
in Suite C at 09:00 after 14 Grover calls plus 13 candidate verifications.

**Try a busier day:**

```bash
uv run placement.py --check
uv run placement.py --sample location --check
```

The quiet sample has only two zero-score answers. On the busy sample, eight of
ten feasible bookings already have score zero, so finding one is much easier.
Compare the discovery counts. To explore random variation, replace `--check`
with `--trials 5`.

## The maths behind the iteration count

Let N be the number of candidates and M the number marked. The initial angle
is `θ = asin(sqrt(M/N))`; a Grover iteration adds `2θ`. After k iterations, the
success probability is `sin²((2k+1)θ)`.

The first peak occurs at `k* = π/(4θ) − 1/2`, which usually is not an integer.
The code compares the integers immediately below and above it, choosing fewer
rounds on ties within floating-point tolerance. This avoids the overshoot that
`floor(π/4 · sqrt(N/M))` can cause when answers are common.

| Free slots out of 8 | Iterations | Chance of a free slot |
|--:|--:|--:|
| 1 | 2 | 94.5% |
| 2 | 1 | 100% |
| 3 | 1 | 84.4% |
| 4 | 0 | 50% |

With half the slots free, every iteration count gives a coin flip, so zero
rounds saves work. With 9 free slots out of 16, zero rounds gives 56.25%; the
approximation would choose one round and reduce that to 31.64%.

## Edit the sample data

[days.json](samples/days.json) holds chapter one's days;
[location.json](samples/location.json) is the busy location for chapters two and
three; [location-quiet.json](samples/location-quiet.json) is chapter four's
default. Both host languages read these files directly.

Provider, room, and slot counts must be powers of two, with at least two slots.
Availability rows have one entry per slot, eligibility flags have one entry per
resource, and durations range from one slot to the whole day. The register packs
indices as `p + P*s + P*S*t`: provider bits first, then room bits, then time bits,
each little-endian.

Q# does not read the files, so [Samples.qs](src/Samples.qs) mirrors the quantum
inputs for the three-openings day and both locations. If you change those
inputs, update the matching Q# table function too. Every host's `--check` mode
compares all mirrored cells and flags; labels such as names remain host-only.
Classical tests separately pin the sample counts and known best bookings, so
intentional changes to their answers require updating those expectations.

## Run with C# or an editor

The C# host requires the .NET 10 SDK. Run from the project root:

```bash
dotnet build QuantumBooking.slnx
dotnet run --project dotnet/QuantumBooking.Host -- --check
```

The default mode is chapter two. Add `--day`, `--earliest`, or `--placement` for
the other chapters. `--duration N`, `--shots N`, `--budget N`, and `--sample NAME`
configure the relevant modes; `--budget` counts only Grover calls. The first
run downloads a private CPython 3.13, creates `.venv-dotnet`, and installs `qdk`,
so this path needs no system Python. It uses a separate environment from the
Python scripts. See [architecture](docs/architecture.md) for the bridge,
source generation, version reproducibility, and shutdown handling.

In **Rider**, open [QuantumBooking.slnx](QuantumBooking.slnx), run
`QuantumBooking.Host`, and use its test runner for `QuantumBooking.Tests`. The
solution also lists the Q#, Python, samples, and documentation. For Q# syntax
highlighting, add [rider/qsharp-textmate](rider/qsharp-textmate) under Settings >
Editor > TextMate Bundles. C# breakpoints work; Python and Q# execute inside the
embedded runtime.

For **Q#-specific editing and debugging**, open this folder in VS Code with the
[QDK extension](https://github.com/microsoft/qdk). Open `src/Samples.qs` and run
`Main`. The [browser editor](https://vscode.dev/quantum) is another entry point.

## Validate the project

```bash
uv run driver.py --check
uv run location.py --check
uv run earliest.py --check
uv run placement.py --check
uv run python -m unittest discover -s tests -v
dotnet test QuantumBooking.slnx
```

The Python tests exercise the Q# runtime, including dense searches, sample
drift, and budget edge cases. NUnit tests cover the C# reference model,
encoding, scoring, and maths. The four host checks exercise complete chapter
runs; their fixed seeds make failures reproducible with the same dependencies.
For chapters three and four, each check asserts a known-good result, not a
statistical success guarantee.

## Where things live

| Path | Purpose |
|---|---|
| [src/](src/) | The four Q# chapters and standalone samples. |
| [qsharp.json](qsharp.json) | Marks the Q# project root. |
| [needle_bridge.py](needle_bridge.py) | Typed shared interface to the QDK compiler and simulator. |
| `driver.py`, `location.py`, `earliest.py`, `placement.py` | One Python host per chapter. |
| [samples/](samples/) | Shared JSON input data. |
| [dotnet/](dotnet/) | C# core model, console host, and NUnit tests. |
| [tests/](tests/) | Python/Q# regression tests. |
| [docs/architecture.md](docs/architecture.md) | Compiler, simulator, and C# embedding details. |
| [pyproject.toml](pyproject.toml), [uv.lock](uv.lock) | Python project requirements and locked dependencies. |
| [requirements.txt](requirements.txt) | Dependency requirement used by the C# host's environment. |

## Possible next chapters

- Estimate physical-qubit and runtime costs, including data-loading gates.
- Explore quantum counting to estimate the number of feasible bookings without
  enumerating them classically.
- Compare placement scores that a reversible oracle can compute.

A full schedule for many clients introduces assignment constraints beyond the
single-booking search taught here. Hardware execution is not implemented or
tested in this repository.

## References and licence

- [Dürr and Høyer: A Quantum Algorithm for Finding the Minimum](https://arxiv.org/pdf/quant-ph/9607014)
- [Boyer, Brassard, Høyer and Tapp: Tight Bounds on Quantum Searching](https://arxiv.org/abs/quant-ph/9605034)
- [QDK source](https://github.com/microsoft/qdk) and [Azure Quantum documentation](https://learn.microsoft.com/azure/quantum/)
- [CSnakes documentation](https://tonybaloney.github.io/CSnakes/)

The project uses the [MIT licence](LICENSE). The TextMate grammar and language
configuration in `rider/qsharp-textmate` come from Microsoft QDK v1.33.0 under
[their MIT notice](rider/qsharp-textmate/LICENSE.microsoft-qdk.txt). Its
`package.json` is local glue for Rider's TextMate importer.
