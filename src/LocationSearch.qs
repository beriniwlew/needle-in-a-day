/// # Chapter two: Grover's search over provider × sub-location × time
///
/// Read the primer at the top of SlotSearch.qs first: a register is an array
/// of amplitudes, gates are arithmetic on that array, measuring samples one
/// index. This chapter adds four ideas on top of it.
///
/// **Sub-registers.** One register of seven qubits is viewed in three parts:
/// two qubits name the provider, two the sub-location, three the slot. The
/// amplitude array still has one entry per seven-bit pattern, 128 entries, and
/// each pattern is one (provider, sub-location, slot) triple. Read as a single
/// little-endian number the pattern equals p + P·s + P·S·t; Decode inverts it.
///
/// **Scratch qubits and "computing a predicate".** An ancilla is a scratch
/// qubit, allocated at 0. Computing a yes/no into it means applying X to it
/// under controls that are true exactly for the patterns where the predicate
/// holds. Afterwards, in every entry of the array, the scratch bit is 1 if that
/// entry's triple satisfies the predicate and 0 otherwise, and this happened for
/// all 128 triples in one pass of gates. Several scratch qubits, one per
/// constraint, then feed a single Controlled Z, which negates exactly the
/// entries whose scratch bits are all 1: the AND of the constraints.
///
/// **Uncomputing.** The scratch must be back at 0 before the diffusion step.
/// If it stayed, the array would effectively be split into groups by scratch
/// value, the mean reflection would act inside each group instead of across
/// the whole array, and the search would fail. Running the `within` block
/// backwards does the cleanup: every step in it was reversible, so running them
/// in reverse returns every scratch qubit to 0 while the sign flips made in the
/// `apply` block remain. Q# also refuses to release a qubit that is not at 0.
///
/// **Lookups (QROM).** "Is provider p free at slot t" is a classical table.
/// Loading it into the circuit means one controlled X onto the scratch qubit
/// per true cell, with controls matching that cell's (p, t) pattern. Each
/// pattern-controlled operation expands to multiple elementary gates, so the cost grows with the table. That is the honest price
/// of data in a quantum search, and the price chapter one's bitmask hides.
///
/// **In-place increment.** Adding k to the slot register permutes the array:
/// the entry for slot t moves to slot t+k, wrapping at the register size.
/// Looking the tables up after the increment, then undoing it, asks "is slot
/// t+k free" for every t at once without storing shifted tables. That is how
/// "two consecutive free slots" gets computed rather than looked up.
///
/// ## Still a toy
/// Grover's advantage is quadratic, and 128 states is not a space where
/// quadratic matters. A classical loop over the same few thousand combinations
/// finishes in microseconds. The value of this chapter is that the oracle
/// finally has the shape Grover's search was invented for: a cheap check over
/// a large space.
namespace LocationSearch {      // A booking predicate built from separate tables, plus the search that uses it.
    import Std.Arithmetic.*;    // IncByI: add a constant to a register in place
    import Std.Arrays.*;        // All
    import Std.Convert.*;       // ResultArrayAsInt
    import Std.Diagnostics.*;   // Fact
    import Std.Math.*;          // BitSizeI
    import Std.Measurement.*;   // MResetEachZ

    /// Runs the search and returns the combined index p + P·s + P·S·t. As in
    /// chapter one, the conversion of results to an integer stays outside the
    /// drawable quantum part.
    operation FindBooking(
        providerFree : Bool[][], subLocationFree : Bool[][],
        qualified : Bool[], suitable : Bool[], durationSlots : Int) : Int {
        // Run the circuit, then pack its measured bits into p + P*s + P*S*t.
        return ResultArrayAsInt(GroverSearch(providerFree, subLocationFree, qualified, suitable, durationSlots));
    }

    /// The quantum part. Same skeleton as chapter one: uniform array, then
    /// (oracle, diffusion) repeated, then measure. Only the oracle differs, and
    /// the register is viewed as three sub-registers.
    operation GroverSearch(
        providerFree : Bool[][], subLocationFree : Bool[][],
        qualified : Bool[], suitable : Bool[], durationSlots : Int) : Result[] {
        // Validate the inputs once and learn the three sizes P, S and T.
        let (providers, subLocations, slots) = Shape(providerFree, subLocationFree, qualified, suitable, durationSlots);

        // N: one amplitude per (provider, sub-location, slot) triple.
        let total = providers * subLocations * slots;

        // M: how many triples are feasible, counted by an ordinary loop, because
        // the iteration count needs it. This is a shortcut taken openly. In a
        // real setting M is unknown, and the unknown-count schedule of Boyer,
        // Brassard, Høyer and Tapp (try random iteration counts from a growing
        // range, check each result classically) finds a marked entry in about
        // √(N/M) oracle calls without ever knowing M.
        let marked = FeasibleCount(providerFree, subLocationFree, qualified, suitable, durationSlots);
        Fact(marked > 0, "No feasible booking exists. Grover's search cannot find what does not exist.");

        // Bits per dimension: 2, 2 and 3 for the sample location.
        let (pBits, sBits, tBits) = (BitSizeI(providers - 1), BitSizeI(subLocations - 1), BitSizeI(slots - 1));

        // One register for all three dimensions, allocated at 0.
        use qs = Qubit[pBits + sBits + tBits];

        // Three views onto it. Slicing with a..b hands out the same qubits, so
        // pReg, sReg and tReg are windows, not copies. Provider bits are the
        // low bits, then sub-location, then slot, which is what makes the whole
        // pattern read as p + P·s + P·S·t.
        // Size-one dimensions have zero bits; the corresponding slice is empty.
        let pReg = qs[0..pBits - 1]; // Provider bits occupy the lowest positions.
        let sReg = qs[pBits..pBits + sBits - 1]; // Room bits follow the provider bits.
        let tReg = qs[pBits + sBits..pBits + sBits + tBits - 1]; // Time bits occupy the high positions.

        // Step 1. H on every qubit: the uniform array over all 128 triples.
        ApplyToEachA(H, qs);

        // Steps 2 and 3. The diffusion operator from chapter one is reused as
        // is: it works on the register as a whole and does not care how the
        // bits are grouped.
        for _ in 1..SlotSearch.GroverIterations(total, marked) { // Zero rounds is valid for a dense marked set.
            // Negate only the amplitudes whose bookings satisfy every constraint.
            MarkFeasibleBookings(providerFree, subLocationFree, qualified, suitable, durationSlots, pReg, sReg, tReg);
            SlotSearch.ReflectAboutUniform(qs); // Mix amplitudes to turn those signs into changed measurement odds.
        }

        // Step 4. Measure all seven qubits, reset them, return the bits.
        return MResetEachZ(qs);
    }

    /// The oracle: negates the amplitude of every feasible triple, nothing else.
    /// Structure: compute each constraint into a scratch qubit, AND them with
    /// one Controlled Z, then run the computation backwards to clear the scratch.
    /// The computation itself lives in ComputeFeasibility, so that chapter three
    /// (EarliestSearch.qs) can reuse it with one more constraint added.
    operation MarkFeasibleBookings(
        providerFree : Bool[][], subLocationFree : Bool[][],
        qualified : Bool[], suitable : Bool[], durationSlots : Int,
        pReg : Qubit[], sReg : Qubit[], tReg : Qubit[]) : Unit {
        // Scratch qubits, one per constraint, all starting at 0:
        //   pFree[k]      provider p is free at slot t+k       (k = 0 .. d−1)
        //   sFree[k]      sub-location s is free at slot t+k   (k = 0 .. d−1)
        //   isQualified   provider p offers the service
        //   isSuitable    sub-location s suits the service
        //   fits          the service ends inside the day
        // Allocating several at once with a tuple is just shorthand.
        use (pFree, sFree, isQualified, isSuitable, fits) =
            (Qubit[durationSlots], Qubit[durationSlots], Qubit(), Qubit(), Qubit());
        within { // Compute the scratch values now; Q# automatically undoes them after apply.
            ComputeFeasibility(providerFree, subLocationFree, qualified, suitable, durationSlots,
                pReg, sReg, tReg, pFree, sFree, isQualified, isSuitable, fits);
        } apply {
            // The AND. Z on `fits`, controlled on every other scratch qubit:
            // negates exactly the entries whose scratch bits are all 1, which
            // are the feasible triples. Controlled Z is symmetric, so `fits`
            // being the "target" is only notation. `+` concatenates arrays.
            Controlled Z(pFree + sFree + [isQualified, isSuitable], fits);
        }
        // Q# has now run the within block backwards: every scratch qubit is 0
        // again and only the sign flips remain. The scratch qubits are released
        // when the operation ends.
    }

    /// Computes the five feasibility constraints into the given scratch qubits,
    /// for every triple at once. Declared `is Adj + Ctl` so a `within` block can
    /// run it backwards to clean up afterwards; everything in here is reversible
    /// (lookups, X gates, the in-place increment), and nothing is measured.
    operation ComputeFeasibility(
        providerFree : Bool[][], subLocationFree : Bool[][],
        qualified : Bool[], suitable : Bool[], durationSlots : Int,
        pReg : Qubit[], sReg : Qubit[], tReg : Qubit[],
        pFree : Qubit[], sFree : Qubit[], isQualified : Qubit, isSuitable : Qubit, fits : Qubit) : Unit is Adj + Ctl {
        // T, the number of slots in the day, read off the table width.
        let slots = Length(providerFree[0]);

        // Two one-dimensional lookups: flip isQualified in every entry whose
        // provider is qualified, and isSuitable per suitable sub-location.
        LookupVector(qualified, pReg, isQualified); // Record whether the selected provider offers this service.
        LookupVector(suitable, sReg, isSuitable);   // Record whether the selected room can host it.

        // A d-slot service cannot start in the last d−1 slots. Flip `fits`
        // for exactly those start slots (the range is empty when d = 1),
        // then X it, so that `fits` reads 1 where the booking does fit,
        // matching the "all scratch bits 1" convention of the Controlled Z.
        for t in slots - durationSlots + 1..slots - 1 {
            ApplyControlledOnInt(t, X, tReg, fits); // First mark each start that runs past closing time.
        }
        X(fits); // Invert: legal starts now have fits=1, illegal starts fits=0.

        // Consecutive slots, computed. For each offset k: add k to the slot
        // register, so every entry's slot pattern becomes t+k; look both
        // tables up at that shifted slot; then subtract k again, which the
        // inner within/apply does automatically. The addition wraps around
        // at the register size, so starts near the end of the day read the
        // morning's cells. Those reads are garbage but harmless: for exactly
        // those starts `fits` is 0 and the final AND cannot fire.
        for k in 0..durationSlots - 1 { // Visit every occupied slot of the proposed service.
            within { // Change only the time register; the chosen provider and room stay the same.
                if k > 0 { // Offset zero already names the start slot, so no addition is needed.
                    IncByI(k, tReg); // Temporarily change every t pattern into (t+k) modulo T.
                }
            } apply {
                LookupTable(providerFree, pReg, tReg, pFree[k]); // Provider free at this offset?
                LookupTable(subLocationFree, sReg, tReg, sFree[k]); // Room free at this offset?
            }
            // Time is restored to t; the two scratch bits retain the answers for offset k.
        }
    }

    /// A lookup over a one-dimensional table of flags. For every index whose
    /// flag is true: flip `target` in the entries where `reg` holds that index.
    /// ApplyControlledOnInt(i, X, reg, target) is chapter one's MarkIndex trick
    /// with X in place of Z: X on the qubits where i has a 0 bit, a controlled
    /// X onto target, the same X gates again. After the loop, target's bit
    /// equals flags[index] in every entry of the array. `is Adj + Ctl` lets Q#
    /// generate the inverse, so the operation may appear inside `within`.
    /// More precisely this XORs the looked-up value into target. With target
    /// initially 0 it computes the value; repeating the lookup clears it again.
    operation LookupVector(flags : Bool[], reg : Qubit[], target : Qubit) : Unit is Adj + Ctl {
        for i in 0..Length(flags) - 1 { // Classical loop builds gates for the table's indices.
            if flags[i] { // False entries need no gate because the target starts at zero.
                ApplyControlledOnInt(i, X, reg, target); // Flip only the component with register pattern i.
            }
        }
    }

    /// A lookup over a two-dimensional table. `rowReg + colReg` is the two
    /// registers concatenated; read as one little-endian number it equals
    /// row + rows·col, the row bits being the low bits, so each true cell is one
    /// pattern-controlled flip on the combined register. There is one such
    /// high-level operation per true cell; each decomposes into multiple
    /// elementary gates, and uncomputation runs the lookups again in reverse.
    operation LookupTable(table : Bool[][], rowReg : Qubit[], colReg : Qubit[], target : Qubit) : Unit is Adj + Ctl {
        let rows = Length(table); // Row count sets the scale of the column bits in the packed index.
        for row in 0..rows - 1 { // Enumerate table data classically while constructing the lookup circuit.
            for col in 0..Length(table[row]) - 1 { // Each column is a time slot.
                if table[row][col] { // Only true cells toggle the initially-zero target.
                    // Low bits encode row; high bits encode column. This gate does not measure either.
                    ApplyControlledOnInt(row + rows * col, X, rowReg + colReg, target);
                }
            }
        }
    }

    /// Validates the inputs and returns (providers, subLocations, slots). Each
    /// count must be a power of two because each becomes a register whose
    /// patterns must map one-to-one onto the indices: three sub-locations on
    /// two qubits would leave a fourth pattern naming nothing, yet the uniform
    /// array would give it the same amplitude as the real ones.
    function Shape(
        providerFree : Bool[][], subLocationFree : Bool[][],
        qualified : Bool[], suitable : Bool[], durationSlots : Int) : (Int, Int, Int) {
        let providers = Length(providerFree);       // One availability row per provider.
        let subLocations = Length(subLocationFree); // One availability row per room.
        // Check nonempty rows before accessing providerFree[0] below.
        Fact(providers > 0 and subLocations > 0, "Need at least one provider and one sub-location.");
        let slots = Length(providerFree[0]); // Use the first row's width as the expected width of every row.
        // Avoid unused basis states; at least two slots also ensures a nonempty search register.
        Fact(IsPowerOfTwo(providers) and IsPowerOfTwo(subLocations) and IsPowerOfTwo(slots) and slots >= 2,
            "Providers, sub-locations and slots must each be a power of two (slots at least 2).");
        // All(predicate, array) is true when the predicate holds for every element.
        Fact(All(row -> Length(row) == slots, providerFree) and All(row -> Length(row) == slots, subLocationFree),
            "Every availability row must have one entry per slot.");
        // Every selectable resource must have exactly one eligibility flag.
        Fact(Length(qualified) == providers and Length(suitable) == subLocations,
            "qualified needs one flag per provider, suitable one per sub-location.");
        // Reject empty/oversized services.
        Fact(durationSlots >= 1 and durationSlots <= slots, "durationSlots must be between 1 and the number of slots.");
        return (providers, subLocations, slots); // A tuple lets the caller unpack all three dimensions at once.
    }

    /// True for 1, 2, 4, 8, …: writing n−1 in binary takes BitSizeI(n−1) bits,
    /// and 2 to that power equals n only when n is itself a power of two.
    function IsPowerOfTwo(n : Int) : Bool {
        return n >= 1 and 2^BitSizeI(n - 1) == n; // Short-circuit protects BitSizeI from negative inputs.
    }

    /// The classical version of the oracle's check, for one triple, written
    /// plainly so the two can be compared line by line: qualified, suitable,
    /// ends inside the day, and both free at every slot the service covers.
    function IsFeasible(
        providerFree : Bool[][], subLocationFree : Bool[][],
        qualified : Bool[], suitable : Bool[], durationSlots : Int,
        p : Int, s : Int, t : Int) : Bool {
        // Inputs come from validated tables and a decoded in-range booking index.
        if not qualified[p] or not suitable[s] or t + durationSlots > Length(providerFree[0]) {
            return false; // Exclude ineligible resources or a service that ends after closing.
        }
        for k in 0..durationSlots - 1 { // Examine every occupied slot, not only the start.
            if not providerFree[p][t + k] or not subLocationFree[s][t + k] {
                return false; // One busy provider or room slot makes the whole booking infeasible.
            }
        }
        return true; // All constraints passed. This function has never allocated a qubit.
    }

    /// Brute force over every (p, s, t): the number of marked entries M, which
    /// GroverIterations needs. This is the classical loop the whole project
    /// says is faster than the search, used here to tune the search. See the
    /// note in GroverSearch about the schedule that avoids knowing M.
    function FeasibleCount(
        providerFree : Bool[][], subLocationFree : Bool[][],
        qualified : Bool[], suitable : Bool[], durationSlots : Int) : Int {
        // Validate here too: hosts call this function without running GroverSearch first.
        let (providers, subLocations, slots) = Shape(providerFree, subLocationFree, qualified, suitable, durationSlots);
        mutable count = 0; // Ordinary classical accumulator; `set` updates it.
        for p in 0..providers - 1 { // Try every provider.
            for s in 0..subLocations - 1 { // Pair that provider with every room.
                for t in 0..slots - 1 { // Try every start, including those rejected at the day boundary.
                    if IsFeasible(providerFree, subLocationFree, qualified, suitable, durationSlots, p, s, t) {
                        set count += 1; // Count one marked state for the known-answer-count search.
                    }
                }
            }
        }
        return count; // This loop costs P*S*T candidate checks; it is not a quantum speedup.
    }

    /// Splits a combined index back into (provider, subLocation, slot). This
    /// inverts index = p + P·s + P·S·t: the provider is the remainder modulo P,
    /// the sub-location is the next "digit" in base S, the slot is what is left.
    function Decode(index : Int, providers : Int, subLocations : Int) : (Int, Int, Int) {
        // Int division discards remainders; % extracts the digit in each dimension.
        return (index % providers, (index / providers) % subLocations, index / (providers * subLocations));
    }
}
