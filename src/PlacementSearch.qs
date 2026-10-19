/// # Chapter four: the best placement, by fewest loose ends
///
/// Chapter three found the earliest booking. This chapter finds the one that
/// leaves the day tidiest, which is what a scheduler's "optimised" placement
/// does: offer the start that sits flush against an existing booking or the
/// edge of the day, so no small unusable gap is left behind. In the grid that
/// rule becomes a score. A booking has a **loose end** on its left when the
/// slot before it is free for both the provider and the sub-location, and on
/// its right when the slot after the service is. The score is the number of
/// loose ends, 0, 1 or 2, and the best placement is a feasible booking with
/// the fewest.
///
/// Read the primers in SlotSearch.qs and LocationSearch.qs first, then
/// EarliestSearch.qs, because the loop here is the same minimum finding with a
/// different score. Three things are new.
///
/// **A score computed from the neighbours.** Chapter two shifted the time
/// register to look at slot t+k. Here it is shifted by −1, which is the same as
/// adding T−1 modulo the register size, to read the slot before the booking, and
/// by d to read the slot after the service. Each neighbour check is an AND of
/// three bits: the neighbouring slot exists (not off the edge of the day), the
/// provider is free there, the sub-location is free there.
///
/// **A comparison on two flags.** "Loose ends below the threshold" has
/// only four cases, so instead of a lookup it is written as logic on the two
/// loose-end bits: below 3 is always true, below 2 means not both, below 1 means
/// neither, below 0 is never. These are separate yes/no flags, not a binary
/// encoding of the score: both set means 1 + 1 = 2 loose ends, not binary 11 = 3.
/// Even this tiny comparator needs its setup and cleanup gates counted.
///
/// **A stop that usually fires.** Zero loose ends cannot be beaten, so the loop
/// stops the moment one is measured and verified, instead of running the budget
/// out as chapter three must. On a quiet day most placements float in free time
/// and only a few sit snug; the search walks down through the scores and ends
/// early. The hosts show that in the call counts.
///
/// Honest note, as always: this is the quantum rendition of a classical policy
/// that a real kernel evaluates in continuous minutes, with buffers, in
/// microseconds. The point is that minimum finding works for any score a
/// circuit can compute, not only "earliest".
namespace PlacementSearch {     // Minimum finding with a placement score rather than a time score.
    import Std.Arithmetic.*;    // IncByI
    import Std.Convert.*;       // IntAsDouble, ResultArrayAsInt
    import Std.Diagnostics.*;   // Fact
    import Std.Math.*;          // BitSizeI, Sqrt, Ceiling, MinD, MinI
    import Std.Measurement.*;   // MResetEachZ
    import Std.Random.*;        // DrawRandomInt

    /// Finds a feasible booking with the fewest loose ends. Returns
    /// (index, callsAtBest, calls, runs), exactly as chapter three does: the
    /// combined index of the best booking found or -1, the oracle calls spent
    /// when it was found, the oracle calls spent in total, and the circuits run.
    /// Unlike chapter three the total is usually well below the budget, because
    /// a booking with zero loose ends ends the search.
    /// `runs` also counts candidate verifications; those and state preparation
    /// are outside the Grover-call budget. Budget 0 allows one uniform sample.
    operation BestPlacement(
        providerFree : Bool[][], subLocationFree : Bool[][],
        qualified : Bool[], suitable : Bool[], durationSlots : Int, budget : Int) : (Int, Int, Int, Int) {
        // Check powers of two, rectangular tables, flag counts, and service duration.
        let (providers, subLocations, slots) = LocationSearch.Shape(providerFree, subLocationFree, qualified, suitable, durationSlots);
        let total = providers * subLocations * slots; // Search all triples, including infeasible ones.
        Fact(budget >= 0, "The budget cannot be negative."); // A cap on Grover calls, not elapsed time.

        // The unknown-count schedule, as in chapter three.
        let growth = 6.0 / 5.0;                   // Increase the trial range by 20% after a miss.
        let maxRange = Sqrt(IntAsDouble(total));   // Never widen the range beyond √N.

        mutable threshold = 3;       // loose ends are 0, 1 or 2, so "fewer than 3" is any feasible booking
        mutable best = -1;           // Sentinel: no verified booking has been found yet.
        mutable callsAtBest = 0;     // Grover calls spent when best last improved.
        mutable calls = 0;           // One call per Grover iteration, excluding classical checks.
        mutable runs = 0;            // One circuit and one candidate verification per attempt.
        mutable range = 1.0;         // First attempt uses zero Grover iterations: a uniform sample.
        mutable done = false;        // Only a verified score of zero proves no improvement exists.

        repeat { // Run the body once before testing the stopping condition.
            // DrawRandomInt includes both endpoints; clamp the draw to the remaining budget.
            let iterations = MinI(DrawRandomInt(0, Ceiling(range) - 1), budget - calls);
            // Prepare a fresh state, search below the current score, then measure one booking.
            let candidate = SearchBelow(providerFree, subLocationFree, qualified, suitable, durationSlots, threshold, iterations);
            set calls += iterations; // Only phase-oracle applications count toward this cap.
            set runs += 1;           // Zero-iteration attempts still consume a circuit and verification.

            // Verify the candidate classically: feasible, and fewer loose ends
            // than the threshold. The score function below is the plain version
            // of what the oracle computes.
            let (p, s, t) = LocationSearch.Decode(candidate, providers, subLocations); // Unpack the measured bits.
            mutable improved = false; // Default to a miss until both feasibility and score pass.
            if LocationSearch.IsFeasible(providerFree, subLocationFree, qualified, suitable, durationSlots, p, s, t) {
                let score = LooseEnds(providerFree, subLocationFree, durationSlots, p, s, t); // Ordinary table reads.
                if score < threshold {  // Equal scores are ties, not progress; keep the existing best.
                    set improved = true; // Do not widen the trial range after a successful improvement.
                    set best = candidate; // Remember the whole booking, not only its score.
                    set callsAtBest = calls; // Preserve the work count at this discovery.
                    set threshold = score; // Ask the next oracle for a strictly lower score.
                    set range = 1.0;       // Restart cheaply because the marked set has changed.
                    set done = score == 0;   // nothing beats a snug fit
                }
            }
            if not improved { // An infeasible booking or a non-improving score both count as a miss.
                set range = MinD(growth * range, maxRange); // Try a wider range of rotations next time.
            }
        } until done or calls >= budget; // End on a proven minimum score or the Grover-call cap.

        return (best, callsAtBest, calls, runs); // Return classical data; no qubits leave this operation.
    }

    /// One Grover search for "feasible and fewer than `threshold` loose ends"
    /// with an explicit iteration count, measured once. The same skeleton as
    /// every chapter; duplicated on purpose so each chapter reads on its own.
    operation SearchBelow(
        providerFree : Bool[][], subLocationFree : Bool[][],
        qualified : Bool[], suitable : Bool[], durationSlots : Int,
        threshold : Int, iterations : Int) : Int {
        // This routine is callable directly, so validate before allocating registers.
        let (providers, subLocations, slots) = LocationSearch.Shape(providerFree, subLocationFree, qualified, suitable, durationSlots);
        Fact(iterations >= 0, "Iterations cannot be negative."); // Zero is the deliberate uniform-sampling case.
        // Each power-of-two dimension needs log2(size) bits; size 1 needs none.
        let (pBits, sBits, tBits) = (BitSizeI(providers - 1), BitSizeI(subLocations - 1), BitSizeI(slots - 1));
        use qs = Qubit[pBits + sBits + tBits]; // Start in the all-zero basis state.
        let pReg = qs[0..pBits - 1]; // Provider occupies the least-significant bits.
        let sReg = qs[pBits..pBits + sBits - 1]; // Room bits follow the provider bits.
        let tReg = qs[pBits + sBits..pBits + sBits + tBits - 1]; // Slot occupies the high bits.

        ApplyToEachA(H, qs); // Make every booking equally likely before any amplification.
        for _ in 1..iterations { // No body executions means an unchanged uniform sample.
            // Mark feasible bookings with a strictly better score by changing their signs.
            MarkSnugFeasibleBookings(providerFree, subLocationFree, qualified, suitable, durationSlots, threshold, pReg, sReg, tReg);
            SlotSearch.ReflectAboutUniform(qs); // Mix amplitudes so the phase marks affect probability.
        }
        return ResultArrayAsInt(MResetEachZ(qs)); // Measure, reset to zero, and pack the bits into an Int.
    }

    /// The oracle: negates the amplitude of every triple that is feasible AND
    /// has fewer loose ends than the threshold. Chapter two's feasibility
    /// computation is reused; the score needs eight more scratch qubits and the
    /// comparison one, all computed inside `within` and so all cleaned up.
    operation MarkSnugFeasibleBookings(
        providerFree : Bool[][], subLocationFree : Bool[][],
        qualified : Bool[], suitable : Bool[], durationSlots : Int, threshold : Int,
        pReg : Qubit[], sReg : Qubit[], tReg : Qubit[]) : Unit {
        // Chapter two's five kinds of constraint: 2*d + 3 scratch qubits, all initially zero.
        use (pFree, sFree, isQualified, isSuitable, fits) =
            (Qubit[durationSlots], Qubit[durationSlots], Qubit(), Qubit(), Qubit());
        // The score's scratch:
        //   prevP, prevS   provider / sub-location free in the slot before
        //   notFirst       the booking does not start in slot 0
        //   leftOpen       all three above: a loose end on the left
        //   nextP, nextS   provider / sub-location free in the slot after the service
        //   notLast        the slot after the service exists
        //   rightOpen      all three above: a loose end on the right
        //   better         loose ends < threshold
        use (prevP, prevS, notFirst, leftOpen, nextP, nextS, notLast, rightOpen, better) =
            (Qubit(), Qubit(), Qubit(), Qubit(), Qubit(), Qubit(), Qubit(), Qubit(), Qubit());
        within { // Record conditions without measuring; this entire setup will be reversed.
            // First compute availability, qualifications, suitability, and the end-of-day guard.
            LocationSearch.ComputeFeasibility(providerFree, subLocationFree, qualified, suitable, durationSlots,
                pReg, sReg, tReg, pFree, sFree, isQualified, isSuitable, fits);
            // Then record whether there is a free neighbouring slot on each side.
            ComputeLooseEnds(providerFree, subLocationFree, durationSlots, pReg, sReg, tReg,
                prevP, prevS, notFirst, leftOpen, nextP, nextS, notLast, rightOpen);
            ComputeBelowThreshold(threshold, leftOpen, rightOpen, better); // Toggle better where the score wins.
        } apply {
            // Feasible AND better: every feasibility bit and the comparison bit.
            Controlled Z(pFree + sFree + [isQualified, isSuitable, fits], better);
        }
        // Automatic uncomputation clears the comparison, neighbours, then feasibility scratch.
        // Only the sign changes survive, so diffusion can mix the booking amplitudes correctly.
    }

    /// Computes the two loose-end bits for every triple at once.
    operation ComputeLooseEnds(
        providerFree : Bool[][], subLocationFree : Bool[][], durationSlots : Int,
        pReg : Qubit[], sReg : Qubit[], tReg : Qubit[],
        prevP : Qubit, prevS : Qubit, notFirst : Qubit, leftOpen : Qubit,
        nextP : Qubit, nextS : Qubit, notLast : Qubit, rightOpen : Qubit) : Unit is Adj + Ctl {
        let slots = Length(providerFree[0]); // The table width is also the time register's wraparound size.

        // The slot before the booking. Adding T−1 to the slot register is the
        // same as subtracting 1 modulo T, because T is the register size. Look
        // both tables up there, then the inner within/apply shifts back.
        within {
            IncByI(slots - 1, tReg); // Move each time pattern to t-1 modulo T.
        } apply {
            LocationSearch.LookupTable(providerFree, pReg, tReg, prevP); // Provider availability at t-1.
            LocationSearch.LookupTable(subLocationFree, sReg, tReg, prevS); // Room availability at t-1.
        }
        // The inner within/apply has restored t, while retaining the two lookup results.
        // "Not the first slot": flip for every start slot from 1 to T−1. For
        // slot 0 the lookups above read slot T−1, garbage that this bit vetoes.
        for t in 1..slots - 1 {
            ApplyControlledOnInt(t, X, tReg, notFirst); // Set the boundary flag for this allowed start.
        }
        // A loose end on the left is the AND of the three: a controlled X with
        // three controls, the quantum AND gate.
        Controlled X([prevP, prevS, notFirst], leftOpen);

        // The slot after the service: shift by d, look up, shift back.
        within {
            IncByI(durationSlots, tReg); // Move to the first slot after the proposed service.
        } apply {
            LocationSearch.LookupTable(providerFree, pReg, tReg, nextP); // Provider availability after the service.
            LocationSearch.LookupTable(subLocationFree, sReg, tReg, nextS); // Room availability after the service.
        }
        // Time is restored again. The notLast flag below rejects wrapped-around reads.
        // "The slot after the service exists": t + d < T, that is t ≤ T−d−1.
        // Empty when the service fills the whole day.
        for t in 0..slots - durationSlots - 1 {
            ApplyControlledOnInt(t, X, tReg, notLast); // This start leaves a real slot after the service.
        }
        Controlled X([nextP, nextS, notLast], rightOpen); // AND the three conditions into the right flag.
    }

    /// Sets `better` to 1 where leftOpen + rightOpen < threshold. Four cases,
    /// because the sum is 0, 1 or 2:
    ///   threshold ≥ 3   always true          X on better
    ///   threshold = 2   not both open        AND into better, then invert
    ///   threshold = 1   neither open         invert both inputs, AND into better, restore
    ///   threshold ≤ 0   never true           leave better at 0
    operation ComputeBelowThreshold(threshold : Int, leftOpen : Qubit, rightOpen : Qubit, better : Qubit) : Unit is Adj + Ctl {
        if threshold >= 3 { // Every possible score (0, 1, 2) is smaller than 3.
            X(better);      // Toggle the initially-zero result unconditionally.
        } elif threshold == 2 { // Scores 0 and 1 win; only two open ends must fail.
            Controlled X([leftOpen, rightOpen], better); // Compute "both open".
            X(better);                                  // Negate it to get "not both open".
        } elif threshold == 1 { // Only score 0 wins: both ends must be closed.
            within { // Temporarily turn each "closed" condition into a 1 control bit.
                X(leftOpen);  // 0 (closed) becomes 1; 1 (open) becomes 0.
                X(rightOpen); // Apply the same inversion to the other side.
            } apply {
                Controlled X([leftOpen, rightOpen], better); // AND the inverted flags, then restore them.
            }
        }
        // Threshold <= 0: do nothing. Nothing beats zero, so better stays 0.
    }

    /// The classical score, for one booking: how many of its two neighbouring
    /// slots are free for both the provider and the sub-location. The plain
    /// version of ComputeLooseEnds, used to verify measured candidates and by
    /// the hosts for their reference lists. `and` short-circuits, so the table
    /// is never indexed off either end.
    function LooseEnds(
        providerFree : Bool[][], subLocationFree : Bool[][], durationSlots : Int,
        p : Int, s : Int, t : Int) : Int {
        let slots = Length(providerFree[0]); // Number of legal time indices.
        mutable ends = 0;                    // This is an ordinary integer score, not a qubit.
        // Test the boundary first; short-circuiting avoids reading slot -1.
        if t > 0 and providerFree[p][t - 1] and subLocationFree[s][t - 1] {
            set ends += 1; // Count a free-for-both neighbour on the left.
        }
        // A service occupies t through t+d-1; its right neighbour is t+d.
        if t + durationSlots < slots and providerFree[p][t + durationSlots] and subLocationFree[s][t + durationSlots] {
            set ends += 1; // Count a free-for-both neighbour on the right.
        }
        return ends; // The result is always 0, 1, or 2 for a valid booking.
    }
}
