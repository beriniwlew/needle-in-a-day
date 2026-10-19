// QuantumBooking.Host: the C# way into the Q# search.
//
// What happens when you press Run
// -------------------------------
// 1. Find the project root, the folder that holds qsharp.json, by walking up
//    from the compiled binary's folder. Everything else is addressed from it.
// 2. Load the sample data from samples/location.json (or samples/days.json for
//    --day). The Python hosts read the same files, so every host sees the same
//    data; no sample is typed into C# code.
// 3. Compute the classical answer: a brute-force list of feasible bookings. It
//    is the reference the quantum result is judged against, and also, honestly,
//    the faster way to get the answer.
// 4. Start an embedded Python interpreter through CSnakes. On the first run
//    CSnakes downloads a self-contained CPython 3.13 (50 to 80 MB, cached in
//    the user's application-data folder), creates `.venv-dotnet` in the project
//    root and installs the `qdk` package into it with uv, as listed in
//    requirements.txt. Later runs reuse all of that.
// 5. Call `needle_bridge.search_bookings` through the C# wrapper that CSnakes
//    generated from the Python type hints at build time. On the Python side
//    that compiles the Q# project, runs the Grover circuit `shots` times on the
//    simulator and returns one measured register value per shot.
// 6. Decode each value into (provider, sub-location, slot), tally a histogram,
//    label every outcome feasible or not with the classical check, and compare
//    the hit rate with the probability Grover's maths predicts.
//
// Command line
//   --duration N   service length in slots (default 2)
//   --shots N      runs of the circuit (default 200)
//   --check        seed the simulator, use at least 400 shots, exit 1 when a
//                  hit rate falls more than ten points below theory
//   --day          run chapter one over the sample days instead
//   --earliest     run chapter three: the earliest feasible booking by minimum finding
//   --budget N     cap chapter three's and four's Grover calls (paper-inspired default)
//   --placement    run chapter four: the placement with the fewest loose ends
//   --sample NAME  which samples/NAME.json to search (default location, or location-quiet for --placement)

using CSnakes.Runtime;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using QuantumBooking;

var options = Options.Parse(args);
var root = ProjectRoot.Find();
var samples = Path.Combine(root, "samples");

// Chapters two to four search one location file. The busy day is the default;
// chapter four defaults to the quiet day, where the score has something to do.
var locationPath = Path.Combine(samples, (options.Sample ?? (options.Placement ? "location-quiet" : "location")) + ".json");

// ---------------------------------------------------------------------------
// Python runtime wiring. WithPython() starts the chain; the rest are independent
// settings on the same builder.
// ---------------------------------------------------------------------------
var builder = Host.CreateApplicationBuilder(args);
builder.Logging.SetMinimumLevel(LogLevel.Warning); // CSnakes narrates the first-run download at Information level
builder.Services
    .WithPython()
    .WithHome(root)                                            // `import needle_bridge` resolves against this folder
    .FromRedistributable("3.13")                                // a private CPython, downloaded once and cached
    .WithVirtualEnvironment(Path.Combine(root, ".venv-dotnet")) // where qdk and its dependencies are installed
    .WithUvInstaller(Path.Combine(root, "requirements.txt"));   // installs them on startup, with uv for speed

using var app = builder.Build();

Console.WriteLine("Starting the embedded Python runtime.");
Console.WriteLine("First run only: download CPython 3.13, create .venv-dotnet, install qdk. Later runs skip this.");
Console.WriteLine();

// Resolving the environment is what triggers the download, the venv creation
// and the package install. The generated extension method then imports the
// module; from here on every call is an ordinary C# method call.
var env = app.Services.GetRequiredService<IPythonEnvironment>();
var bridge = env.NeedleBridge();

try
{
    // Read the actual Q# sample tables; equal feasible counts alone cannot detect drift.
    if (options.Check)
    {
        var mismatches = bridge.SampleMismatches(root).ToList();
        if (mismatches.Count > 0)
        {
            return Verdict(mismatches, "");
        }
    }

    return options.Day ? RunDays() : options.Earliest ? RunEarliest() : options.Placement ? RunPlacement() : RunLocation();
}
finally
{
    // Release on the creating thread even if a check fails or the search throws.
    // This happens before `app` disposes the embedded interpreter.
    bridge.Release();
}

// ---------------------------------------------------------------------------
// Chapter two: provider × sub-location × time, from samples/location.json.
// ---------------------------------------------------------------------------
int RunLocation()
{
    var location = LocationFile.Read(locationPath);
    var duration = options.Duration;
    var shots = options.Shots;

    // The classical reference. ClassicalSearch applies exactly the predicate
    // the quantum oracle computes in superposition, one booking at a time.
    var reference = ClassicalSearch.Feasible(location, duration);
    var feasible = reference.ToHashSet();

    // The Q# side counts the same thing with its own loop; the two must agree
    // or the oracle and the reference disagree about what feasible means.
    var markedByQSharp = (int)bridge.FeasibleCount(root, location.ProviderFree, location.SubLocationFree, location.Qualified, location.Suitable, duration);

    Console.WriteLine($"{location.Providers.Count} providers x {location.SubLocations.Count} sub-locations x {location.Slots.Count} slots = {location.States} states on {location.Qubits} qubits, service of {duration} slot(s)");
    Console.WriteLine($"classical loop finds {reference.Count} feasible bookings; the Q# count says {markedByQSharp}");
    if (options.Check && markedByQSharp != reference.Count)
    {
        return Verdict([$"Q# count {markedByQSharp} differs from the classical loop {reference.Count}"], "");
    }
    if (reference.Count == 0)
    {
        Console.WriteLine("nothing to search for");
        return 0;
    }

    var iterations = GroverMath.Iterations(location.States, reference.Count);
    var theory = GroverMath.SuccessProbability(location.States, reference.Count);

    // One quantum run per shot. Each value is the whole register, packed as
    // p + P·s + P·S·t; Booking.Decode unpacks it.
    var measured = bridge.SearchBookings(root, location.ProviderFree, location.SubLocationFree, location.Qualified, location.Suitable, duration, shots, options.Seed);
    var counts = measured
        .Select(value => Booking.Decode((int)value, location))
        .GroupBy(b => b)
        .ToDictionary(g => g.Key, g => g.Count());
    var hits = counts.Where(kv => feasible.Contains(kv.Key)).Sum(kv => kv.Value);
    var rate = (double)hits / shots;

    Console.WriteLine($"{iterations} Grover iteration(s), {shots} shots; outcomes seen, most frequent first:");
    foreach (var (booking, count) in counts.OrderByDescending(kv => kv.Value).Take(14))
    {
        var tag = feasible.Contains(booking) ? "FEASIBLE  " : "infeasible";
        Console.WriteLine($"  {booking.Describe(location),-28} {tag} {count,5}  {new string('#', (int)Math.Round(40.0 * count / shots))}");
    }
    if (counts.Count > 14)
    {
        Console.WriteLine($"  ... and {counts.Count - 14} more outcomes");
    }
    Console.WriteLine($"measured a feasible booking {rate:P1} of the time; theory says {theory:P1}");
    Console.WriteLine("classical reference: " + string.Join(", ", reference.Select(b => b.Describe(location))));

    if (!options.Check)
    {
        return 0;
    }

    var problems = new List<string>();
    if (markedByQSharp != reference.Count)
    {
        problems.Add($"Q# count {markedByQSharp} differs from the classical loop {reference.Count}");
    }
    if (rate < theory - 0.10)
    {
        problems.Add($"measured {rate:P1}, theory {theory:P1}");
    }
    return Verdict(problems, "the Q# count matches the classical loop and the hit rate is within 10 points of theory");
}

// ---------------------------------------------------------------------------
// Chapter one: one provider's day, from samples/days.json, through the same bridge.
// ---------------------------------------------------------------------------
int RunDays()
{
    var file = DayFile.Read(Path.Combine(samples, "days.json"));
    var problems = new List<string>();

    foreach (var day in file.Days)
    {
        var marked = Enumerable.Range(0, day.Free.Count).Where(i => day.Free[i]).ToList();
        Console.WriteLine();
        Console.WriteLine($"{day.Name}: {marked.Count} of {day.Free.Count} slots free");

        if (marked.Count == 0)
        {
            // The oracle flips the sign of marked states. With none marked it is
            // the identity, the diffusion step has nothing to amplify, and a
            // measurement is a uniformly random slot. The host answers this itself.
            Console.WriteLine("  Nothing to find. Grover's search amplifies marked states; with none marked it");
            Console.WriteLine("  returns a uniformly random slot, so the host answers this one classically: none.");
            continue;
        }

        var iterations = GroverMath.Iterations(day.Free.Count, marked.Count);
        var theory = GroverMath.SuccessProbability(day.Free.Count, marked.Count);

        var measured = bridge.SearchDay(root, day.Free, options.Shots, options.Seed);
        var counts = measured.GroupBy(v => (int)v).ToDictionary(g => g.Key, g => g.Count());
        var hits = marked.Sum(i => counts.GetValueOrDefault(i));
        var rate = (double)hits / options.Shots;

        Console.WriteLine($"  {iterations} Grover iteration(s), {options.Shots} shots");
        for (var i = 0; i < day.Free.Count; i++)
        {
            var count = counts.GetValueOrDefault(i);
            Console.WriteLine($"  {file.DayStartHour + i:00}:00  {(day.Free[i] ? "FREE" : "busy")}  {count,5}  {new string('#', (int)Math.Round(40.0 * count / options.Shots))}");
        }
        Console.WriteLine($"  measured a free slot {rate:P1} of the time; theory says {theory:P1}");

        if (options.Check && rate < theory - 0.10)
        {
            problems.Add($"{day.Name}: measured {rate:P1}, theory {theory:P1}");
        }
    }

    return options.Check ? Verdict(problems, "every sample day's hit rate is within 10 points of theory") : 0;
}

// ---------------------------------------------------------------------------
// Chapter three: the earliest feasible booking, by Dürr and Høyer's minimum
// finding. Grover's search inside a classical loop, with a budget instead of a
// stopping rule, because the algorithm cannot know when it has found the minimum.
// ---------------------------------------------------------------------------
int RunEarliest()
{
    var location = LocationFile.Read(locationPath);
    var duration = options.Duration;

    // The classical answer: every feasible booking, then the smallest slot.
    var reference = ClassicalSearch.Feasible(location, duration);
    Console.WriteLine($"{location.Providers.Count} providers x {location.SubLocations.Count} sub-locations x {location.Slots.Count} slots = {location.States} states on {location.Qubits} qubits, service of {duration} slot(s)");
    if (reference.Count == 0)
    {
        Console.WriteLine("no feasible booking exists; nothing to find");
        return 0;
    }

    var earliestSlot = reference.Min(b => b.Slot);
    var atEarliest = reference.Where(b => b.Slot == earliestSlot).ToList();
    Console.WriteLine($"classical scan: {location.States} checks; earliest feasible slot is {location.Slots[earliestSlot]}, held by {string.Join(", ", atEarliest.Select(b => b.Describe(location)))}");

    var budget = options.Budget ?? GroverMath.DurrHoyerBudget(location.States);
    Console.WriteLine($"quantum budget: {budget} Grover oracle calls{(options.Budget is null ? " (paper-inspired default; no proved success bound for this variant)" : "")}");

    // One run of the whole hybrid algorithm. The Q# side draws random iteration
    // counts, so the seed covers both measurements and that randomness.
    var (index, callsAtBest, calls, runs) = bridge.EarliestBooking(root, location.ProviderFree, location.SubLocationFree, location.Qualified, location.Suitable, duration, budget, options.Seed);
    if (index < 0)
    {
        Console.WriteLine($"found nothing within the budget ({calls} Grover calls, {runs} circuits and classical candidate verifications)");
        return options.Check ? Verdict(["the seeded run found no feasible booking"], "") : 0;
    }

    var booking = Booking.Decode((int)index, location);
    var isEarliest = atEarliest.Contains(booking);
    var verdict = isEarliest ? "the true earliest" : reference.Contains(booking) ? "feasible but later" : "NOT FEASIBLE";
    Console.WriteLine($"found {booking.Describe(location)} after {callsAtBest} Grover calls; {verdict}");
    var stop = booking.Slot == 0 ? "the first slot cannot be beaten" : "the Grover-call budget ran out";
    Console.WriteLine($"{calls} Grover calls plus {runs} classical candidate verifications ({runs} circuits); {stop}");

    return options.Check ? Verdict(isEarliest ? [] : [$"the seeded run found {booking.Describe(location)}, not the earliest"], "the seeded run found the earliest feasible booking") : 0;
}

// ---------------------------------------------------------------------------
// Chapter four: the placement with the fewest loose ends, by the same minimum
// finding as chapter three with a different score. A score of zero ends the
// search early, which chapter three's "earliest" rarely can.
// ---------------------------------------------------------------------------
int RunPlacement()
{
    var location = LocationFile.Read(locationPath);
    var duration = options.Duration;

    var reference = ClassicalSearch.Feasible(location, duration);
    Console.WriteLine($"{Path.GetFileNameWithoutExtension(locationPath)}: {location.Providers.Count} providers x {location.SubLocations.Count} sub-locations x {location.Slots.Count} slots = {location.States} states on {location.Qubits} qubits, service of {duration} slot(s)");
    if (reference.Count == 0)
    {
        Console.WriteLine("no feasible booking exists; nothing to place");
        return 0;
    }

    // Score every feasible booking classically: the reference and the N-check baseline.
    var scores = reference.ToDictionary(b => b, b => ClassicalSearch.LooseEnds(location, duration, b));
    var bestScore = scores.Values.Min();
    var bestSet = scores.Where(kv => kv.Value == bestScore).Select(kv => kv.Key).ToList();
    Console.WriteLine($"{reference.Count} feasible bookings; loose ends: {scores.Values.Count(v => v == 0)} with none, {scores.Values.Count(v => v == 1)} with one, {scores.Values.Count(v => v == 2)} with two");
    Console.WriteLine($"classical scan: {location.States} checks; best placements ({bestScore} loose end(s)): {string.Join(", ", bestSet.Select(b => b.Describe(location)))}");

    var budget = options.Budget ?? GroverMath.DurrHoyerBudget(location.States);
    Console.WriteLine($"quantum budget: {budget} Grover oracle calls (candidate verification is additional work)");

    var (index, callsAtBest, calls, runs) = bridge.BestPlacement(root, location.ProviderFree, location.SubLocationFree, location.Qualified, location.Suitable, duration, budget, options.Seed);
    if (index < 0)
    {
        Console.WriteLine($"found nothing within the budget ({calls} Grover calls, {runs} circuits and classical candidate verifications)");
        return options.Check ? Verdict(["the seeded run found no feasible booking"], "") : 0;
    }

    var booking = Booking.Decode((int)index, location);
    var score = ClassicalSearch.LooseEnds(location, duration, booking);
    var isBest = bestSet.Contains(booking);
    var verdict = isBest ? "a best placement" : scores.ContainsKey(booking) ? "feasible but looser" : "NOT FEASIBLE";
    var stop = score == 0 && calls < budget ? "stopped early: nothing beats zero loose ends" : "ran the budget out";
    Console.WriteLine($"found {booking.Describe(location)} ({score} loose end(s)) after {callsAtBest} Grover calls; {verdict}");
    Console.WriteLine($"{calls} Grover calls plus {runs} classical candidate verifications ({runs} circuits), {stop}");

    return options.Check ? Verdict(isBest ? [] : [$"the seeded run found {booking.Describe(location)}, which is not a best placement"], "the seeded run found a placement with the fewest loose ends") : 0;
}

// The same tolerance the Python hosts use: at 400 seeded shots the binomial
// noise is a point or two, so a ten-point shortfall means a wrong circuit.
static int Verdict(List<string> problems, string passed)
{
    Console.WriteLine();
    if (problems.Count > 0)
    {
        Console.WriteLine("CHECK FAILED");
        problems.ForEach(p => Console.WriteLine("  " + p));
        return 1;
    }

    Console.WriteLine($"CHECK PASSED: {passed}");
    return 0;
}

/// <summary>Command-line options, parsed by hand because the host has eight flags and no need for a library.</summary>
sealed record Options(int Duration, int Shots, bool Check, bool Day, bool Earliest, bool Placement, int? Budget, string? Sample)
{
    /// <summary>A seeded simulator makes the check reproducible; a negative seed means unseeded.</summary>
    public long Seed => Check ? 42 : -1;

    public static Options Parse(string[] args)
    {
        var duration = 2;
        var shots = 200;
        var check = false;
        var day = false;
        var earliest = false;
        var placement = false;
        int? budget = null;
        string? sample = null;
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--duration" when i + 1 < args.Length: duration = int.Parse(args[++i]); break;
                case "--shots" when i + 1 < args.Length: shots = int.Parse(args[++i]); break;
                case "--check": check = true; break;
                case "--day": day = true; break;
                case "--earliest": earliest = true; break;
                case "--placement": placement = true; break;
                case "--sample" when i + 1 < args.Length: sample = args[++i]; break;
                case "--budget" when i + 1 < args.Length: budget = int.Parse(args[++i]); break;
                default: throw new ArgumentException($"Unknown argument '{args[i]}'. Use --duration N, --shots N, --check, --day, --earliest, --placement, --budget N, --sample NAME.");
            }
        }

        // The check wants enough shots for the ten-point tolerance to be meaningful.
        return new Options(duration, check ? Math.Max(shots, 400) : shots, check, day, earliest, placement, budget, sample);
    }
}
