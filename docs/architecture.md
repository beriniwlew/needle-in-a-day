# How the hosts call Q#

[Back to the learning guide](../README.md)

The four Python scripts and the C# console host use the same typed
[needle_bridge.py](../needle_bridge.py) interface. Q# owns the search circuits;
the hosts load samples, calculate classical references, and display results.
The C# host embeds Python through CSnakes to reach the QDK API used here.

```text
Python chapter scripts ---------------------+
                                            v
C# host -> CSnakes -> embedded CPython -> needle_bridge.py
                                            |
                                            v
                                       qdk package
                                            |
                                            v
                                       Q# compiler
                                            |
                                            v
                                  sparse-state simulator
```

## Compilation and execution

`qdk.init(project_root=...)` reads [qsharp.json](../qsharp.json) and the Q# files
under [src/](../src/), compiles them, and exposes callable handles through
`qdk.code`. The bridge remembers the loaded root so consecutive calls reuse the
compiled context. Initialising another root replaces that context.

`qsharp.run(callable, shots, *args, seed=...)` converts Python arguments into
Q# values and runs the operation once per shot. A list of booleans becomes a
`Bool[]`, for example. Each execution prepares qubits, applies gates on the
simulator, measures, and returns ordinary values to Python. Q# functions such
as the iteration calculation execute classical logic in the same interpreter.

The simulator computes amplitudes on a conventional computer; these calls do
not contact quantum hardware. The two-slot location circuit explicitly
allocates seven index qubits and seven scratch qubits. Placement adds nine
more scratch qubits, giving 23 explicit qubits. Library decompositions can
require additional temporary qubits.

The bridge uses simple type hints as its cross-language contract. Inputs are
boolean tables and scalar settings; outputs include integer lists, tuples of
search results and counters, probabilities, and sample-mismatch messages.
Qubits never cross the host boundary.

## How C# gets typed methods

At build time, the CSnakes source generator reads `needle_bridge.py`, registered
as an additional file in
[QuantumBooking.Host.csproj](../dotnet/QuantumBooking.Host/QuantumBooking.Host.csproj).
It generates C# methods from the Python function signatures. Relevant mappings
include:

| Python | Generated C# |
|---|---|
| `int` | `long` |
| `float` | `double` |
| `list[int]` | `IReadOnlyList<long>` |
| `list[list[bool]]` | `IReadOnlyList<IReadOnlyList<bool>>` |

The [Location record](../dotnet/QuantumBooking.Core/Location.cs) uses compatible
collection types, so the host can pass deserialised JSON tables directly to the
bridge without building another representation.

At runtime, [Program.cs](../dotnet/QuantumBooking.Host/Program.cs) configures:

- `WithHome(root)` so Python imports the bridge from the project root.
- `FromRedistributable("3.13")` to load a private CPython distribution.
- `WithVirtualEnvironment(...)` to use `.venv-dotnet` for packages.
- `WithUvInstaller(...)` to install the dependency requirement from
  [requirements.txt](../requirements.txt).

Resolving `IPythonEnvironment` initialises the runtime and package setup.
`env.NeedleBridge()` exposes the generated methods. CSnakes loads CPython as a
shared library inside the .NET process; the search call does not start a Python
subprocess or send a network request. Initial runtime/package installation can
require downloads, and the installer may check packages on later starts too.

Each generated call acquires Python's interpreter lock, converts C# arguments,
invokes the Python function, and converts its result back. Inside that function,
Python takes the same QDK path as the standalone scripts. C# breakpoints apply
to the host; they do not step through the Q# simulator as C# source.

## Randomness and reproducibility

For `--check`, the hosts use seed 42. Chapters one and two seed measurement
sampling. Chapters three and four also seed Q#'s classical random source, since
it chooses how many Grover iterations to try. In the bridge, a negative seed
means an unseeded run.

Matching samples, seeds, and simulator versions give matching measurement
outcomes between hosts. The environments are installed separately:

- `uv sync` resolves the Python scripts from [uv.lock](../uv.lock), currently
  locking QDK 1.33.1.
- The C# environment installs `qdk>=1.33` from `requirements.txt`; that range
  does not pin it to the lockfile's version.

If seeded results differ across environments or after an upgrade, compare the
installed QDK versions before treating the difference as a circuit regression.
Printed formatting can differ between languages even when measured counts
match.

## Shutdown on the creating thread

Initialisation stores Q# callable handles in `qdk.code`. Their underlying Rust
objects must be released on the thread that created them. Embedded interpreter
shutdown can otherwise drop them on another thread and print runtime warnings.

The bridge's `release()` calls `qdk.init()` without a project, replacing the
loaded context, then clears its cached root. The C# host invokes this in a
`finally` block before disposing the application and embedded interpreter.
Standalone Python scripts do not need that embedding-specific cleanup call.

## Boundaries of this example

This project implements local simulation and classical comparison. It has no
hardware submission path. Hardware support would need its own implementation
and validation; the host/kernel separation by itself is not evidence that
these circuits and adaptive loops can be submitted unchanged.

The reported Grover-call count covers phase-oracle applications. Candidate
verification, state preparation, table-loading gates, and uncomputation have
costs beyond that number. The counters are useful for following the algorithm,
not for claiming an end-to-end speedup over the classical reference.

See [CSnakes](https://tonybaloney.github.io/CSnakes/) and
[QDK](https://github.com/microsoft/qdk) for the libraries used by this project.
