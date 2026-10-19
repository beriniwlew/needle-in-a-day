# Needle in a day: Grover's search over appointment slots, in Q#, Python and C#

A learning project, deliberately small, in four chapters. Grover's search is the
needle-in-a-haystack algorithm; here the haystack is a day of appointment slots
and the needle is a booking that works. Chapter one searches one provider's day.
Chapter two searches provider × sub-location × time, which is where the oracle
stops being a lookup of the answer and starts computing something. Chapter
three finds the earliest feasible booking, which is where Grover's search
becomes a subroutine inside a classical loop and stops needing to know how many
answers exist. Chapter four finds the placement that leaves the fewest loose
ends, an "optimised" placement policy turned into a score.

Four Python chapter scripts and a C# solution drive the same Q# code.
QuantumBooking embeds Python through CSnakes. Matching Python and C# modes
print the same results for the same seed, because they run the same circuit
on the same simulator and read the same sample data.

It is not a product feature. A classical loop over a location's few thousand
combinations finishes in microseconds; Grover's quadratic speedup only matters
over spaces far too large to enumerate. The point is to see the algorithm's real
shape, including its costs, on a problem small enough to check by hand.

## Vocabulary

- **Location**: the whole place being booked, with its day of slots.
- **SubLocation**: a bookable space inside it. The samples call them Suite A to D.
- **Provider**: the person who performs the service.
- **Slot**: one start time. The samples use eight hourly slots from 09:00.

The quantum register is provider bits, then sub-location bits, then slot bits,
each little-endian, so a measured value reads p + P·s + P·S·t.

## Layout

```
qsharp.json                    Q# project manifest; marks this folder as the Q# project root
src/SlotSearch.qs              chapter one: oracle from a bitmask, diffusion, iteration maths
src/LocationSearch.qs          chapter two: oracle computed from tables, QROM lookups, duration via an in-place increment
src/EarliestSearch.qs          chapter three: the earliest feasible booking by minimum finding, with the unknown-count schedule
src/PlacementSearch.qs         chapter four: the placement with the fewest loose ends, minimum finding over a computed score
src/Samples.qs                 the sample day and sample location, mirrored by hand from samples/ so the Q# can run alone
samples/location.json          the sample location: providers, sub-locations, slots, availability, flags
samples/days.json              chapter one's sample days
samples/location-quiet.json    a quiet day for chapter four, where only two placements sit snug
needle_bridge.py               the typed Python bridge every host calls; CSnakes generates C# from its type hints
tests/test_quantum.py           Python/Q# regression checks, including actual sample-data drift
driver.py                      chapter one host (Python)
location.py                    chapter two host (Python)
earliest.py                    chapter three host (Python)
placement.py                   chapter four host (Python)
pyproject.toml, uv.lock        the Python hosts' dependency (qdk), managed by uv; .venv is created by `uv sync`
requirements.txt               the same dependency for the C# host's own venv (.venv-dotnet, created on first run)
QuantumBooking.slnx            the .NET solution; also lists the Q#, Python, sample and doc files as solution items
dotnet/QuantumBooking.Core     location model and JSON readers, booking encode/decode, classical brute force, Grover maths
dotnet/QuantumBooking.Host     console app: classical reference, then the quantum search through CSnakes
dotnet/QuantumBooking.Tests    NUnit tests for the classical side and the sample files
rider/qsharp-textmate/         Q# TextMate grammar from microsoft/qdk v1.33.0 (MIT) for Rider
LICENSE                        MIT
```

## Samples

All sample data lives in `samples/`. `location.json` is the busy day chapters
two and three search; `location-quiet.json` is the quiet day chapter four needs;
`days.json` holds chapter one's sample days. The
Python and C# hosts read the files directly, so no sample is typed into host
code and editing a file changes every host at once. Q# cannot read files, so
`src/Samples.qs` mirrors the same data by hand for running the Q# on its own;
the hosts' `--check` modes compare the arrays returned by the Q# sample
functions against JSON, cell by cell and flag by flag. This includes the
three-openings day and both locations. Labels such as provider names live only
in JSON. Separately, the classical tests pin the busy location's 26 feasible
one-slot bookings and 10 two-slot ones.

For a guided reading, start at `Samples.Main`, follow its call into
`SlotSearch.FindFreeSlot`, then read the location, earliest, and placement
chapters in order. Comments explain each meaningful step: which index a
register represents, what a gate changes, why a boundary check exists, and
how scratch qubits are restored. The amplitude-array analogy uses real numbers
because these circuits stay real; quantum amplitudes in general are complex.

## Chapter one: one provider's day

Eight hourly slots, so three index qubits. A bitmask of free slots becomes the
oracle, one phase-marking routine per free slot. The diffusion operator amplifies the
free indices and a measurement returns one of them with the probability in the
table below. `src/SlotSearch.qs` opens with a primer for developers with no physics
background, one mental model (a register is an array of numbers) and a Q#
syntax cheat sheet, then comments every statement against that model.
`src/LocationSearch.qs` adds the four ideas chapter two needs on top.

Honest note: the answer is wired into the oracle before the search starts, so
building the oracle costs as much as reading the bitmask. The chapter stays
because it is the smallest correct Grover circuit and the easiest histogram to
read.

## Chapter two: provider × sub-location × time

Four providers, four sub-locations, eight slots: 128 states on 7 qubits. The
inputs stay separate and small: a provider availability table, a sub-location
availability table, a qualification list, a suitability list. The oracle
evaluates each constraint into its own ancilla qubit and flips the phase only
when all of them hold. For a two-slot service the time register is incremented
in place, the tables are looked up again at the shifted time, and the increment
is undone, so "two consecutive free slots" is computed rather than stored.

Each table lookup is a QROM, one pattern-controlled flip per true cell. Its gate
count grows with the table, which is the honest cost of loading data into a
quantum search, and the cost chapter one hides. The tables here hold 72 bits
while the space searched has 128 states; the gap widens with every dimension.

| providers | sub-locations | slots | qubits | states | feasible (2-slot) | iterations | chance of a feasible result |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 1 | 1 | 8 | 3 | 8 | 3 | 1 | 84.4% |
| 4 | 4 | 8 | 7 | 128 | 10 | 2 | 97.6% |

In the sample location Casey is not qualified and Suite D lacks the equipment,
so neither appears in a feasible booking however free they are.

## Chapter three: the earliest feasible booking

A scheduler rarely asks "is there a booking?"; it asks "what is the first one?".
Chapter three answers that with Dürr and Høyer's minimum finding. Hold a
threshold slot, starting at the end of the day. Search for a feasible booking
earlier than the threshold, using chapter two's oracle with one more scratch bit
for "slot < threshold". Each find becomes the best so far and lowers the
threshold. Every candidate is checked by ordinary code before it is trusted. The
loop ends when a budget of oracle calls is spent or slot 0 is found, because the
algorithm has no way to know that its current best is the true minimum.

The inner search cannot know how many bookings beat the threshold, so it uses
the schedule of Boyer, Brassard, Høyer and Tapp: pick the iteration count at
random below a range that starts at one and grows by six fifths on every miss,
up to √N. That removes the shortcut chapters one and two take when they count
the marked states with a classical loop first.

The default budget is `ceil(22.5·√N + 1.4·lg²N)`, or 324 for the sample,
inspired by the [Dürr–Høyer paper](https://arxiv.org/pdf/quant-ph/9607014).
The paper proves at least one-half success for its algorithm and time model:
it starts from a random threshold and includes initialisation work. This toy
starts from an end-of-day sentinel and caps only Grover oracle calls. Borrowing
the expression does **not** establish that guarantee for this variant.

The hosts report Grover calls and classical candidate verifications separately.
Every circuit produces one candidate to verify, even with zero Grover rounds.
The fixed-seed check finds Drew in Suite B at 10:00 after 19 Grover calls and
finishes after 324 calls plus 80 candidate verifications. These counts exclude
state preparation and the gates inside each oracle; they are not elapsed time.
The classical reference scans 128 triples. The gap between "found" and
"stopped" is the cost of not knowing when to stop. `--budget 0` deliberately
allows one uniform sample and its classical verification, with no Grover calls.

## Chapter four: the best placement, by fewest loose ends

An "optimised" placement policy offers the start that sits flush against an
existing booking or the edge of the day, so no small unusable gap is left. In
the grid that becomes a score: a booking has a loose end on a side when the
neighbouring slot there is free for both the provider and the sub-location. Zero
loose ends is a snug fit, two is a booking floating in free time. Chapter four
runs chapter three's minimum finding over that score, which shows the loop works
for any score a circuit can compute, not only "earliest".

Two things are new in the oracle. The neighbours are read with the shift trick
from chapter two, by −1 for the slot before and by d for the slot after, each
AND-ed with "that slot exists". And the comparison is logic on a two-bit number
rather than a lookup: below 3 is always, below 2 is not both, below 1 is
neither. The two bits are separate flags whose sum is the score, not a binary
encoding of 0, 1, or 2. Setup and uncomputation also cost gates. A score of zero cannot be beaten, so the search
stops the moment it verifies one, where chapter three had to run its budget out.

The busy day is a poor showcase: eight of its ten feasible two-slot bookings
already sit snug, and the first try usually wins. The quiet day is the point:
45 feasible bookings, of which 2 leave no loose ends, 22 leave one and 21 float.
The seeded run walks down through the scores and finds Blake in Suite C at
09:00 after 14 Grover oracle calls plus 13 classical candidate verifications,
then stops. A verification checks feasibility and, when feasible, computes the
score; it is not a free operation. The classical scan is 128 candidate checks.

## Requirements

- Python 3.10 or newer and [uv](https://docs.astral.sh/uv/). `uv sync` creates
  the virtual environment and installs the one dependency, `qdk`. Without uv,
  `pip install -r requirements.txt` into any environment works too.
- The .NET 10 SDK, for the C# solution. Its first run downloads a private
  CPython 3.13 through CSnakes, so that side needs no system Python at all.
- Rider or VS Code are optional; see their sections below. Nothing here needs
  quantum hardware or a cloud account: everything runs on the simulator inside
  the qdk package.

## Run it with Python

```
git clone https://github.com/beriniwlew/needle-in-a-day.git
cd needle-in-a-day
uv sync                          # once; creates .venv with qdk and pyqir
uv run driver.py                 # chapter one histograms
uv run driver.py --circuit       # plus the drawn circuit
uv run location.py               # chapter two histogram, two-slot service
uv run location.py --duration 1  # one-slot service
uv run driver.py --check         # seeded; exit 1 if a hit rate is >10 points under theory
uv run location.py --check       # seeded; also checks the Q# count against the Python loop
uv run earliest.py               # chapter three: one trial, paper-inspired budget
uv run earliest.py --trials 5    # several trials with a summary of oracle calls
uv run earliest.py --budget 80   # a tighter cap than the paper-inspired default
uv run earliest.py --check       # seeded; exit 1 unless the true earliest is found
uv run placement.py              # chapter four on the quiet day
uv run placement.py --sample location --trials 5   # the busy day, several trials
uv run placement.py --check      # seeded; exit 1 unless a best placement is found
uv run python -m unittest discover -s tests -v  # regression tests against the Q# runtime
```

## Run it with C# in Rider

Open `QuantumBooking.slnx`. The solution explorer shows the three projects plus
solution folders holding the Q#, Python, sample and doc files, so everything is
reachable from one window. Rider has no Q# language support; add
`rider/qsharp-textmate` under Settings > Editor > TextMate Bundles for syntax
highlighting of `.qs` files, and optionally the Python Community Edition plugin
for the `.py` files.

- **QuantumBooking.Host** is the run configuration. Arguments: `--duration N`,
  `--shots N`, `--check`, `--day` (chapter one over the sample days), `--earliest`
  (chapter three), `--placement` (chapter four), `--budget N` (cap the Grover
  calls of chapters three and four; classical verification is additional work) and `--sample NAME` (which `samples/NAME.json`
  to search; chapter four defaults to the quiet day). The first run downloads a private CPython 3.13 (50 to 80 MB,
  cached in your application-data folder), creates `.venv-dotnet` in this folder
  and installs `qdk` into it with uv. That took about ninety seconds here; later
  runs take about ten seconds, most of it the simulation itself. Breakpoints in
  the C# work; Python and Q# run inside the same process but are opaque to the
  debugger.
- **QuantumBooking.Tests** runs in Rider's unit test runner, or with
  `dotnet test QuantumBooking.slnx`. The tests pin the classical side:
  the sample files, the location shape, the booking encoding, the feasible
  counts, the earliest booking, the loose-ends score and the Grover maths.

From a terminal: `dotnet build QuantumBooking.slnx`, then
`dotnet run --project dotnet/QuantumBooking.Host -- --check`.

## VS Code, when you want the real Q# tooling

Install the **Azure Quantum Development Kit (QDK)** extension and open this same
folder. `qsharp.json` marks the project root. Open `src/Samples.qs`, run
`Main`, and you get completions, diagnostics, the Q# debugger, the circuit view
and a histogram. The browser build at https://vscode.dev/quantum works without
installing anything.

## How the hosts call the Q#

Both host languages call the Q#, through one shared path. Neither calls it directly as a
library, because the Q# toolchain only ships as a Python package: Python calls
that package, and C# calls Python, which calls that package.

```
the four Python chapter scripts ────┐
                                    ├─ needle_bridge.py ─ qdk package ─ Q# compiler ─ sparse-state simulator
C# Host ─ CSnakes ─ embedded CPython ┘        (Rust inside, loaded in-process)
```

**What calling Q# actually does.** The `qdk` package is a thin Python layer over
a Rust library that contains the Q# compiler and a simulator.

- `qdk.init(project_root=...)` reads `qsharp.json` and every file under `src/`,
  parses, type-checks and compiles them into a program held in memory, and
  exposes one callable handle per Q# operation or function in the `qdk.code`
  namespace.
- `qsharp.run(callable, shots, *args, seed=...)` converts the Python arguments
  to Q# values, a list of booleans becoming a `Bool[]`, then executes the
  operation once per shot. Each shot allocates qubits, applies the gates by
  updating a classical vector of amplitudes, performs the measurements with
  seeded randomness, and hands back the operation's return value as a Python
  value. Nothing quantum happens anywhere: the simulator is classical code
  computing what a quantum computer would do, which is feasible because the
  chapter-two two-slot circuit explicitly allocates seven index qubits plus
  seven scratch qubits; chapter four adds nine more, for 23 explicit qubits.
  Library gate decompositions can require additional temporary qubits.
- Q# functions that touch no qubits, such as the iteration count, run in the
  same interpreter as ordinary classical code.

**The Python hosts** call those three things through `needle_bridge.py`, which
wraps them in functions with plain type hints. Only data crosses the boundary,
lists of booleans in and lists of integers out. Qubits exist solely inside the
simulator for the duration of a shot.

**The C# host** never sees Q# at all; it sees typed C# methods.

- At build time, the CSnakes source generator reads `needle_bridge.py`, listed as
  an additional file in the Host project, and generates a class with one method
  per Python function. `list[list[bool]]` becomes
  `IReadOnlyList<IReadOnlyList<bool>>` and `list[int]` becomes
  `IReadOnlyList<long>`, which is why the `Location` record uses exactly those
  types, and why the same record binds to the sample JSON with no mapping code.
- At run time, CSnakes loads a private CPython 3.13 as a shared library inside
  the dotnet process. No subprocess, no sockets. The home setting puts this
  folder on Python's module path so the import resolves, and the virtual
  environment setting points the interpreter at `.venv-dotnet`, where uv
  installed `qdk` from `requirements.txt`.
- Each C# call takes Python's global interpreter lock, builds Python objects
  from the C# arguments, calls the function, and converts the result back.
  Inside that call, Python does exactly what the scripts do.

**Why the detour exists.** Microsoft removed the .NET host for Q# in 2024, so
Python and VS Code are the only supported ways in. The alternatives were
shelling out to a Python process, which loses the typed API, or compiling to
Quantum Intermediate Representation and finding a runtime for it, which .NET
does not have.

**One consequence of embedding.** The compiled Q# program lives in Python as
callable handles that must be released on the thread that created
them. The bridge's `release()` does that before the host disposes the
interpreter; without it, shutdown prints one warning per handle. Plain Python
scripts never need the call.

**What would change for real hardware.** Almost nothing on the host side. The
compiled program would be submitted as a job through Azure Quantum instead of
run on the local simulator, with a wait of minutes rather than milliseconds,
and classical bits would still be what comes back. The shape seen here, a host
that prepares inputs and a kernel that returns bits, is the shape every quantum
program has.

## The math, for eight slots

With `M` marked states out of `N`, one Grover iteration rotates the state by
`2θ` where `θ = asin(sqrt(M/N))`. The first probability peak is at
`k* = π/(4θ) − 1/2`. Compare the whole iteration counts immediately below
and above that peak using `sin²((2k+1)θ)`, and choose the better one. Ties
(within floating-point tolerance) use fewer rounds. This avoids the overshoot
the approximation `floor(π/4 · sqrt(N/M))` can cause when answers are common.

| free slots of 8 | iterations | chance of a free slot |
|--:|--:|--:|
| 1 | 2 | 94.5% |
| 2 | 1 | 100% |
| 3 | 1 | 84.4% |
| 4 | 0 | 50% |

With half the day free, every Grover iteration count gives a coin flip, so
zero rounds saves work. With 9 free slots out of 16, zero rounds gives 56.25%
success; the old approximation chose one round and reduced it to 31.64%.
Grover's search is most useful when the needle is rare.

## Honest notes and possible next chapters

- Chapters one and two compute `M`, the number of feasible bookings, with a
  classical loop before searching. Chapter three shows the way around that, and
  the price: a budget instead of a stopping rule.
- Chapters three and four are the same loop with different scores. Any score a
  circuit can compute works, which is also the limit: the score has to be
  computed inside the oracle, at QROM prices, for every candidate.
- This minimum-finding variant is probabilistic even with the default budget. The `--check` runs
  are seeded, so they assert one reproducible known-good run, not a probability.
- **What it would cost for real.** The qdk package includes a resource
  estimator; one bridge call would report physical qubits and runtime for the
  chapter-two oracle on a fault-tolerant machine, for this location and for one
  ten times larger. A possible next chapter.
- **How many feasible bookings exist, without enumerating them.** Quantum
  counting, phase estimation on the Grover step. Heavier machinery, and the one
  question here that is about reporting rather than booking.
- Finding a schedule for many clients at once is an assignment problem, not a
  search, and belongs to optimisation methods rather than to Grover.

## References

- [Dürr and Høyer: A Quantum Algorithm for Finding the Minimum](https://arxiv.org/pdf/quant-ph/9607014)
- [Boyer, Brassard, Høyer and Tapp: Tight Bounds on Quantum Searching](https://arxiv.org/abs/quant-ph/9605034)
- Q# and the QDK: https://github.com/microsoft/qdk and https://learn.microsoft.com/azure/quantum/
- CSnakes: https://tonybaloney.github.io/CSnakes/
- The grammar in `rider/qsharp-textmate` is copied from the QDK repository at tag v1.33.0
  under the MIT license (see `LICENSE.microsoft-qdk.txt` there). The `package.json` beside it
  is local glue so Rider's TextMate importer recognises the folder.

## License

MIT, see `LICENSE`. The one exception is `rider/qsharp-textmate`, whose grammar
and language configuration are Microsoft's, also MIT, under the notice kept in
`LICENSE.microsoft-qdk.txt` there.
