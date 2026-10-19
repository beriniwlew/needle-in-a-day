/// # Chapter three: the earliest feasible booking
///
/// Chapters one and two answer "is there a booking?". A scheduler asks "what is
/// the first one?". This chapter answers it with Dürr and Høyer's minimum
/// finding, which is Grover's search wrapped in a classical loop, and in doing
/// so it removes the one shortcut the earlier chapters took: knowing in advance
/// how many entries are marked.
///
/// Read the primers at the top of SlotSearch.qs and LocationSearch.qs first.
/// This chapter adds three ideas.
///
/// **A quantum search inside a classical loop.** Hold a threshold slot, which
/// starts at "the end of the day". Search for a feasible booking whose slot is
/// earlier than the threshold. Every time one is found, it becomes the best so
/// far and its slot becomes the new threshold. Each round is a complete chapter
/// two search with one more constraint in the oracle, "slot < threshold", and
/// every answer is checked by ordinary code before it is trusted, because a
/// search can return a wrong index. The loop ends when a budget of oracle calls
/// is spent, or when slot 0 is found, which nothing can beat. The algorithm has
/// no way to know that the current best is the true earliest; the budget is what
/// makes it stop. Real quantum algorithms are hybrids like this one.
///
/// **Searching without knowing M.** The inner search cannot know how many
/// bookings beat the current threshold, so it cannot compute the ideal
/// iteration count. The schedule of Boyer, Brassard, Høyer and Tapp replaces
/// that knowledge with randomness: keep a range, start it at 1, pick the
/// iteration count uniformly at random below the range, run, check the result,
/// and on failure grow the range by a constant factor (6/5 here) up to √N. A
/// random count lands in a good region often enough that the expected cost
/// stays within a constant of the known-M ideal.
///
/// **A comparison in the oracle.** "slot < threshold" is computed into a scratch
/// qubit like the other constraints. With eight slots it is written as a lookup,
/// one flip per slot below the threshold; a real comparator circuit would cost
/// about log T gates instead, but the lookup is clearer and T is eight.
///
/// **What the numbers say.** We borrow 22.5·√N + 1.4·lg²N from the published
/// Dürr–Høyer time bound as a demonstration budget: 324 for 128 entries.
/// The paper counts initialisation work and starts from a random threshold;
/// this variant starts with a sentinel and caps only Grover oracle calls.
/// Its success probability is not proved by copying the paper's constant.
/// Every measured candidate also needs a classical verification, including
/// zero-iteration runs. The hosts report both counts. Neither count includes
/// the gates inside each oracle, so neither is a wall-clock speed comparison.
namespace EarliestSearch {      // The hybrid loop and its time-threshold oracle.
    import Std.Convert.*;       // IntAsDouble, ResultArrayAsInt
    import Std.Diagnostics.*;   // Fact
    import Std.Math.*;          // BitSizeI, Sqrt, Lg, Ceiling, MinD, MinI
    import Std.Measurement.*;   // MResetEachZ
    import Std.Random.*;        // DrawRandomInt

    /// Finds the earliest feasible booking. Returns (index, callsAtBest, calls, runs):
    /// the combined index p + P·s + P·S·t of the best booking found, or -1 if
    /// none was found; the oracle calls spent up to the moment that best was
    /// found; the oracle calls spent in total, which is the whole budget unless
    /// slot 0 turned up; and how many circuits were run and measured, counting
    /// the zero-iteration runs that are plain random samples. The gap between
    /// callsAtBest and calls is the price of not knowing when to stop.
    ///
    /// `budget` caps only Grover oracle calls. `runs` also counts classical
    /// candidate verifications, one per circuit. A zero budget still permits
    /// one uniform sample and its verification, because repeat runs once first.
    /// DurrHoyerBudget supplies a paper-inspired default, not a proved bound
    /// for this variant. Hosts can lower it to explore the success tradeoff.
    operation EarliestBooking(
        providerFree : Bool[][], subLocationFree : Bool[][],
        qualified : Bool[], suitable : Bool[], durationSlots : Int, budget : Int) : (Int, Int, Int, Int) {
        // Validate once and learn P, S, T; N is the number of entries.
        let (providers, subLocations, slots) = LocationSearch.Shape(providerFree, subLocationFree, qualified, suitable, durationSlots);
        let total = providers * subLocations * slots; // One basis state per possible booking.
        Fact(budget >= 0, "The budget cannot be negative."); // Zero is allowed; negative work is not.

        // The schedule's growth factor and ceiling: any factor strictly between
        // 1 and 4/3 works for the analysis; 6/5 is the paper's choice.
        let growth = 6.0 / 5.0;                    // Widen the trial range by 20% after a miss.
        let maxRange = Sqrt(IntAsDouble(total));    // Stop widening at √N; do not count answers first.

        // The loop's state. `mutable` allows later `set`; `let` values stay fixed.
        mutable threshold = slots;   // "slot < T" is true for every slot: any feasible booking beats it
        mutable best = -1;           // combined index of the best booking so far
        mutable callsAtBest = 0;     // oracle calls spent when `best` was last improved
        mutable calls = 0;           // Grover iterations spent
        mutable runs = 0;            // circuits run AND candidates verified, one of each per attempt
        mutable range = 1.0;         // the schedule's current upper bound on the iteration count
        mutable done = false;        // set when slot 0 is found, which nothing can beat

        // repeat/until is Q#'s loop with the condition checked after the body.
        repeat {
            // Pick the iteration count uniformly below the range (DrawRandomInt
            // is inclusive on both ends), but never past the remaining budget.
            let iterations = MinI(DrawRandomInt(0, Ceiling(range) - 1), budget - calls);

            // One complete search with the threshold oracle, then a measurement.
            let candidate = SearchBelow(providerFree, subLocationFree, qualified, suitable, durationSlots, threshold, iterations);
            set calls += iterations; // Each Grover iteration applies the phase oracle once.
            set runs += 1;           // Even zero Grover iterations require a measurement and check.

            // Never trust a measurement: check the candidate with ordinary code.
            let (p, s, t) = LocationSearch.Decode(candidate, providers, subLocations); // Unpack the measured integer.
            if LocationSearch.IsFeasible(providerFree, subLocationFree, qualified, suitable, durationSlots, p, s, t) and t < threshold {
                // An improvement: adopt it, tighten the threshold, and restart
                // the schedule, because the number of marked entries just shrank.
                set best = candidate;    // Remember this verified booking, not just its slot.
                set callsAtBest = calls; // Record the Grover-call count when this improvement appeared.
                set threshold = t;      // The next search must find a strictly earlier slot.
                set range = 1.0;        // Restart with cheap uniform sampling for the new predicate.
                set done = t == 0;      // No nonnegative slot index can beat the start of the day.
            } else {
                // A miss: widen the range for the next random iteration count.
                set range = MinD(growth * range, maxRange);
            }
        } until done or calls >= budget; // Stop at a known lower bound or the Grover-call cap.

        return (best, callsAtBest, calls, runs); // Plain classical values cross back to the host.
    }

    /// One Grover search for "feasible and slot < threshold" with an explicit
    /// iteration count, measured once. The same skeleton as the earlier
    /// chapters: uniform array, (oracle, diffusion) repeated, measure. With zero
    /// iterations it is a uniformly random sample, which the schedule relies on.
    operation SearchBelow(
        providerFree : Bool[][], subLocationFree : Bool[][],
        qualified : Bool[], suitable : Bool[], durationSlots : Int,
        threshold : Int, iterations : Int) : Int {
        // Recheck shape because hosts can also call this search operation directly.
        let (providers, subLocations, slots) = LocationSearch.Shape(providerFree, subLocationFree, qualified, suitable, durationSlots);
        Fact(iterations >= 0, "Iterations cannot be negative."); // An empty loop means zero, not negative, work.
        Fact(threshold >= 0 and threshold <= slots, "Threshold must be between zero and the slot count.");
        // A dimension of size 1 needs zero bits; its register slice is empty.
        let (pBits, sBits, tBits) = (BitSizeI(providers - 1), BitSizeI(subLocations - 1), BitSizeI(slots - 1));
        use qs = Qubit[pBits + sBits + tBits]; // Allocate one all-zero register for the whole booking.
        let pReg = qs[0..pBits - 1];          // Low bits name the provider; slices share qubits.
        let sReg = qs[pBits..pBits + sBits - 1]; // Middle bits name the room/sub-location.
        let tReg = qs[pBits + sBits..pBits + sBits + tBits - 1]; // High bits name the start slot.

        ApplyToEachA(H, qs); // Give every booking the same starting amplitude, 1/√N.
        for _ in 1..iterations { // With zero iterations, measure that uniform state directly.
            // Change only the signs of the feasible bookings earlier than the threshold.
            MarkEarlyFeasibleBookings(providerFree, subLocationFree, qualified, suitable, durationSlots, threshold, pReg, sReg, tReg);
            SlotSearch.ReflectAboutUniform(qs); // Interference turns those signs into changed probabilities.
        }
        return ResultArrayAsInt(MResetEachZ(qs)); // Sample, reset qubits, pack the bits little-endian.
    }

    /// The oracle: negates the amplitude of every triple that is feasible AND
    /// starts before the threshold. Chapter two's constraint computation is
    /// reused as is; one scratch qubit, `early`, is added for the comparison,
    /// and the Controlled Z gains one more control.
    operation MarkEarlyFeasibleBookings(
        providerFree : Bool[][], subLocationFree : Bool[][],
        qualified : Bool[], suitable : Bool[], durationSlots : Int, threshold : Int,
        pReg : Qubit[], sReg : Qubit[], tReg : Qubit[]) : Unit {
        // d provider bits + d room bits + four flags; every scratch qubit starts at 0.
        use (pFree, sFree, isQualified, isSuitable, fits, early) =
            (Qubit[durationSlots], Qubit[durationSlots], Qubit(), Qubit(), Qubit(), Qubit());
        within { // Compute scratch values reversibly; Q# will undo this whole block after apply.
            // Keep the original booking register while recording each feasibility condition.
            LocationSearch.ComputeFeasibility(providerFree, subLocationFree, qualified, suitable, durationSlots,
                pReg, sReg, tReg, pFree, sFree, isQualified, isSuitable, fits);

            // The comparison "slot < threshold" as a lookup: flip `early` in
            // every entry whose slot pattern is one of 0 .. threshold−1. With
            // threshold = T this marks every slot; with threshold = 0 nothing.
            for t in 0..threshold - 1 {
                ApplyControlledOnInt(t, X, tReg, early); // Toggle early only for this slot pattern.
            }
        } apply {
            // Feasible AND early: all six kinds of scratch bit must be 1.
            Controlled Z(pFree + sFree + [isQualified, isSuitable, fits], early);
        }
        // All scratch qubits are now 0 again; the booking amplitudes retain the sign change.
    }

    /// A demonstration budget using the published time-bound expression.
    /// The historical name records its source, not a success guarantee for our
    /// sentinel-initialised, Grover-call-only variant. See the chapter introduction.
    function DurrHoyerBudget(total : Int) : Int {
        Fact(total >= 1, "The search space must hold at least one state."); // log2 needs positive input.
        let n = IntAsDouble(total); // Convert to floating point for sqrt and log.
        let lg = Lg(n);            // Lg is base-2 logarithm, not the natural logarithm.
        return Ceiling(22.5 * Sqrt(n) + 1.4 * lg * lg); // Round up to a whole-call budget (324 for N=128).
    }
}
