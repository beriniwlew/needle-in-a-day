/// # Chapter one: Grover's search over one provider's day
///
/// ## Read this first if you have never touched quantum code
///
/// You do not need physics to follow this file. You need one mental model.
///
/// **For these circuits, model a register of n qubits as an array of 2^n
/// signed numbers called amplitudes.** In general amplitudes can be complex
/// numbers; these circuits only need real numbers, so ordinary squares suffice.
/// This is a mathematical model, not an array a quantum program can inspect.
/// Index i of the array belongs to the bit pattern i: with three
/// qubits, index 5 is the pattern 101. The array always satisfies one rule, the
/// squares of all entries add up to 1, which is what lets the squares act as
/// probabilities. **Measuring** the register draws one index at random, index i
/// with probability amplitude², and from then on the register holds only that
/// pattern. You cannot read the amplitude array on hardware. A measurement
/// replaces the superposition with its sampled pattern; measuring again without
/// changing the state repeats that pattern. A fresh independent sample needs a
/// newly prepared state. Gates transform the amplitudes before measurement.
///
/// **Gates are fixed arithmetic operations on the array.** The ones used here:
///
/// - `H` (Hadamard) on one qubit: for every pair of indices that differ only in
///   that qubit's bit, with amplitudes a (bit 0) and b (bit 1), replace them by
///   (a+b)/√2 and (a−b)/√2. Applied to every qubit of an all-zero register it
///   produces the uniform array, every entry 1/√N. That is how "consider every
///   index at once" starts.
/// - `X` on one qubit: swap the amplitudes of every pair of indices that differ
///   in that bit. The quantum NOT.
/// - `Z` on one qubit: negate the amplitude of every index whose bit is 1.
/// - `Controlled G(controls, target)`: apply G only to the indices where every
///   control bit is 1; leave all other entries alone. `Controlled Z` therefore
///   negates exactly the entries whose index has all the involved bits set.
///
/// Every gate is reversible, so Q# can run any sequence of them backwards
/// (`Adjoint`), which the `within` blocks below rely on.
///
/// **A phase flip is just negating an entry.** Negating an amplitude does not
/// change its square, so on its own it does not change the measurement odds. It
/// becomes visible only when a later step adds amplitudes together, which is
/// exactly what the diffusion step does.
///
/// **Grover's search, as array arithmetic.** Start uniform. Negate the entries
/// of the "good" indices (the oracle). Reflect every entry about the mean of
/// all entries (the diffusion). The good entries were below the mean, being
/// negative, so the reflection lifts them well above it, and the bad entries,
/// sitting slightly above the mean, drop a little to compensate. Repeat the pair
/// a suitable number of times and the good indices can gain most of the
/// squared weight. More rounds do not always help; the probability oscillates,
/// so GroverIterations chooses when to stop. Then measure.
///
/// ## Q# syntax for C# and Python developers
///
/// - `operation` is a routine that may touch qubits; `function` is pure
///   classical code and may not.
/// - `let` declares an immutable value. `mutable` and `set` are for the rare
///   variable that changes.
/// - `use qs = Qubit[n];` allocates n qubits, all 0, released at the end of the
///   block; they must be back at 0 by then.
/// - `a..b` is an inclusive range with step +1; it is empty when a > b.
///   `for _ in 1..k` repeats k times; `_` discards the loop variable.
/// - `Bool[]` is a list of flags; `Bool[][]` is a list of rows. `Qubit[]`
///   holds references to qubits, not their amplitudes or measured values.
/// - `x -> x` is a lambda; `2^n` is integer power; `&&&` and `<<<` are bitwise
///   AND and left shift; `and`, `or`, `not` are the boolean operators.
/// - `Result` is a measurement outcome, `Zero` or `One`.
/// - `within { A } apply { B }` runs A, then B, then A backwards. Think of a
///   try/finally for reversible code: set something up, use it, undo it.
/// - `is Adj + Ctl` after a signature supports the operation's inverse and
///   controlled form. Operations in `within` need an inverse (`Adj`) so they
///   can be undone; `Ctl` additionally permits conditional use on control qubits.
/// - `Fact(condition, message)` is an assertion. `Unit` is `void`.
///
/// ## Why this chapter is a cheat, and kept anyway
/// The oracle is built from the bitmask itself: one phase-marking routine per free slot. The
/// answer is wired into the circuit before the search starts, so building the
/// oracle costs as much as reading the bitmask classically. It is still the
/// smallest correct Grover circuit and the easiest histogram to read, which is
/// why it stays as chapter one. Chapter two (LocationSearch.qs) computes the
/// predicate from separate inputs instead of storing the answer.
namespace SlotSearch {          // Groups related routines, like a C# namespace.
    // Imports work like C# `using static`: they bring the listed library's
    // callables into scope. Each comment names what this file uses from it.
    import Std.Arrays.*;        // Count, Most, Tail
    import Std.Convert.*;       // IntAsDouble, ResultArrayAsInt
    import Std.Diagnostics.*;   // Fact
    import Std.Math.*;          // PI, Sqrt, ArcSin, Sin, Floor, MaxI, BitSizeI
    import Std.Measurement.*;   // MResetEachZ

    /// Runs the search and converts the measured bits into a slot index.
    ///
    /// Kept separate from GroverSearch because turning measurement results into
    /// an integer compares `Result` values, which the circuit renderer cannot
    /// draw. Everything drawable stays in GroverSearch.
    operation FindFreeSlot(free : Bool[]) : Int {
        // ResultArrayAsInt reads the results little-endian: results[0] is bit 0.
        return ResultArrayAsInt(GroverSearch(free));
    }

    /// The quantum part: build the array, amplify the free slots, measure.
    /// Returns one measurement result per qubit, never compared or converted.
    operation GroverSearch(free : Bool[]) : Result[] {
        // N: the number of slots, and therefore the length of the amplitude array.
        let total = Length(free);

        // M: how many entries are "good". Count applies the lambda to every
        // element and counts the trues; `x -> x` is the identity on a Bool.
        let marked = Count(x -> x, free);

        // Two preconditions the maths relies on. A register of n qubits has
        // exactly 2^n entries, so the slot count must be a power of two:
        // BitSizeI(total - 1) is the number of bits needed to write the largest
        // index, and 2 to that power must give total back. And with nothing
        // marked the oracle changes nothing, the array stays uniform, and a
        // measurement is a uniformly random slot; the host handles that case.
        Fact(total >= 2 and 2^BitSizeI(total - 1) == total,
            "The number of slots must be a power of two (2, 4, 8, 16, ...).");
        Fact(marked > 0,
            "No slot is free. Grover's search cannot find what does not exist.");

        // Allocate the register: three qubits for eight slots. The amplitude
        // array now has entry 0 equal to 1 and every other entry 0, which is
        // what "all qubits are 0" means.
        use qs = Qubit[BitSizeI(total - 1)];

        // Step 1. H on each qubit in turn. Once all are done every entry of the
        // array equals 1/√N: the uniform starting point. ApplyToEachA is a
        // foreach that applies the given gate to each qubit of the register.
        ApplyToEachA(H, qs);

        // Steps 2 and 3, repeated. One round is "negate the good entries", then
        // "reflect every entry about the mean". GroverIterations says how many
        // rounds give the better probability around the first peak.
        for _ in 1..GroverIterations(total, marked) { // Empty when zero rounds is the best choice.
            MarkFreeSlots(free, qs);   // Phase marking changes signs, not probabilities by itself.
            ReflectAboutUniform(qs);   // Interference converts those relative signs into changed odds.
        }

        // Step 4. Measure every qubit: one index is drawn with probability
        // amplitude², and each qubit reports its bit of that index as Zero or
        // One. MResetEachZ also returns each qubit to 0 afterwards, which Q#
        // requires before the `use` block ends.
        return MResetEachZ(qs);
    }

    /// The oracle: negates the amplitude of every free slot's index.
    ///
    /// Negating several distinct entries is the same as negating them one at a
    /// time, so the oracle is one MarkIndex per free slot. This loop is also
    /// exactly where chapter one cheats: the free slots are enumerated by
    /// ordinary classical code while the circuit is being built.
    operation MarkFreeSlots(free : Bool[], qs : Qubit[]) : Unit {
        for index in 0..Length(free) - 1 { // A classical loop reads each flag when building the circuit.
            if free[index] { // Busy slots need no phase mark.
                MarkIndex(index, qs); // Negate the amplitude for exactly this free-slot pattern.
            }
        }
    }

    /// Negates the amplitude of one index and leaves every other entry alone.
    ///
    /// The sign-flipping construction used here negates the entry whose bits are
    /// all 1 (Controlled Z). To hit an arbitrary index instead: for every bit of
    /// the index that is 0, apply X to that qubit. Each X swaps entries that
    /// differ in that bit, so after these swaps the wanted index sits at the
    /// all-ones position. Fire Controlled Z there. Then apply the same X gates
    /// again, which swaps everything back, carrying the negated sign along.
    /// `within { X gates } apply { Controlled Z }` says exactly that: Q# runs
    /// the X gates, then the Z, then the X gates in reverse. X is its own
    /// inverse, so "in reverse" is the same gates again.
    ///
    /// Bit order is little-endian throughout the project: bit b of the index
    /// lives on qs[b], so qs[0] is the least significant bit. ResultArrayAsInt
    /// assumes the same order when it reads the measurement results.
    operation MarkIndex(index : Int, qs : Qubit[]) : Unit {
        within { // Set up the selected pattern; the same X gates will undo this setup after apply.
            for bit in 0..Length(qs) - 1 { // Examine the desired index one binary digit at a time.
                // `index &&& (1 <<< bit)` isolates bit b of the index. Zero
                // means this qubit needs an X so the pattern lines up.
                if (index &&& (1 <<< bit)) == 0 {
                    X(qs[bit]); // Relabel this bit so the chosen pattern becomes all ones.
                }
            }
        } apply {
            // Most(qs) is every qubit but the last, Tail(qs) the last one. Z on
            // the last qubit, controlled on all the others, negates exactly the
            // all-ones entry. The gate is symmetric: any qubit could play
            // "target" with the same result.
            Controlled Z(Most(qs), Tail(qs));
        }
    }

    /// Grover's diffusion: reflects every amplitude about the mean amplitude.
    /// In array terms, for every index i: new[i] = 2·mean − old[i], up to
    /// an overall sign. This circuit implements the negative of that reflection;
    /// negating every amplitude together leaves all measurement probabilities unchanged.
    ///
    /// Why this circuit does that. Reflecting about the mean is the same as
    /// reflecting about the uniform array, the one with every entry equal,
    /// because that array is "the mean, everywhere". H on every qubit maps the
    /// uniform array onto a single entry at index 0, and maps it back again,
    /// since H is its own inverse. So: H everything, reflect about index 0, H
    /// everything again. "Reflect about index 0" means negate every entry except
    /// index 0 which, up to an overall sign that no measurement can see, is the
    /// same as negating index 0 alone. Negating index 0 alone is MarkIndex(0):
    /// X on every qubit, Controlled Z, X on every qubit. Written out with
    /// within/apply, that is the code below.
    operation ReflectAboutUniform(qs : Qubit[]) : Unit {
        within {
            ApplyToEachA(H, qs);   // move "uniform" onto index 0
            ApplyToEachA(X, qs);   // move index 0 onto the all-ones position
        } apply {
            Controlled Z(Most(qs), Tail(qs));   // negate that one entry
        }
        // Q# has now undone the within block, X on every qubit then H on every
        // qubit, so the array is back in its usual indexing with the reflection
        // applied.
    }

    /// Choose the better integer iteration count on either side of the first
    /// probability peak. Zero iterations is a useful answer when many slots work.
    ///
    /// The picture behind the formula. All good entries always share one value
    /// and all bad entries share another, so the whole array can be described
    /// by a single angle θ between a "bad" direction and the current state,
    /// with sin θ = √(M/N) at the start. Each round rotates the state by 2θ
    /// towards the "good" direction. The first peak is at (2k+1)θ = π/2,
    /// so its real-valued iteration count is k = π/(4θ) − 1/2. A circuit can
    /// only do whole iterations: compare the integers just below and above it.
    /// The common approximation floor(π/4 · √(N/M)) assumes rare answers and
    /// can overshoot badly: with 9 of 16 marked it lowers success from 56.25%
    /// to 31.64%. Using the actual angle avoids that loss. We choose the first
    /// peak, rather than paying for later rotations that might get closer.
    function GroverIterations(total : Int, marked : Int) : Int {
        // Reject an empty search or impossible count before dividing or taking asin.
        Fact(total >= 1 and marked >= 1 and marked <= total, "Need 1 <= marked <= total.");
        // IntAsDouble prevents integer division; asin recovers the starting angle.
        let theta = ArcSin(Sqrt(IntAsDouble(marked) / IntAsDouble(total)));
        let peak = PI() / (4.0 * theta) - 0.5;  // Whole iterations rarely land exactly here.
        let lower = MaxI(0, Floor(peak));       // Try the integer before the peak; never negative.
        let upper = lower + 1;                 // Also try the next integer, just after the peak.
        let lowerAmplitude = Sin(IntAsDouble(2 * lower + 1) * theta); // Good-state component.
        let upperAmplitude = Sin(IntAsDouble(2 * upper + 1) * theta); // Same component one round later.
        // Squaring turns the component into a probability. Treat tiny floating-point
        // differences as a tie, and save an oracle call on ties (notably M = N/2).
        if upperAmplitude * upperAmplitude > lowerAmplitude * lowerAmplitude + 1e-12 {
            return upper;                      // The extra round improves the chance of success.
        }
        return lower;                          // No improvement: use the cheaper circuit.
    }

    /// The probability that one run returns a free slot: sin²((2k+1)θ).
    /// After k rounds the state sits at angle (2k+1)θ from the bad direction,
    /// and the squared component along the good direction is the chance of
    /// measuring a good index. For N = 8: one free slot 94.5%, two exactly
    /// 100%, three 84.4%, four 50% with no iterations. For half marked,
    /// extra Grover rounds cannot improve on that coin flip.
    function SuccessProbability(total : Int, marked : Int) : Double {
        let iterations = GroverIterations(total, marked); // Validate counts and choose the circuit length.
        let theta = ArcSin(Sqrt(IntAsDouble(marked) / IntAsDouble(total))); // Starting good-state angle.
        let s = Sin(IntAsDouble(2 * iterations + 1) * theta); // Good-state component after the rotations.
        return s * s;                                      // Its square is the measurement probability.
    }
}
