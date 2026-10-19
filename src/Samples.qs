/// # Samples: a place to start reading and running the project
///
/// Main runs chapter one. SampleLocation runs chapter two. SamplePlacement
/// runs chapter four. The table functions below contain ordinary classical
/// data mirrored from samples/*.json, because Q# does not read those files.
/// Every host's --check mode compares these actual Q# values with the JSON,
/// cell by cell; matching only the number of feasible bookings is not enough.
///
/// Start with Main, then follow FindFreeSlot into SlotSearch.qs. Read
/// LocationSearch.qs, EarliestSearch.qs, and PlacementSearch.qs in that order.
/// `let` names a value, `[...]` makes an array, and `(a, b)` makes a tuple.
/// A function returns classical data; an operation may also manipulate qubits.
namespace Samples { // Runnable examples and the data they actually consume.
    /// Chapter one: search the three-openings day. Main is the project's entry point.
    operation Main() : Int {
        let free = DayFree(); // Eight flags, indexed 0..7; true means an allowed start.
        return SlotSearch.FindFreeSlot(free); // Run the circuit and return one measured slot index.
    }

    /// Mirrors the "three openings" entry in samples/days.json.
    function DayFree() : Bool[] {
        // Indices 2, 4, 7 are 11:00, 13:00, 16:00 when the day starts at 09:00.
        return [false, false, true, false, true, false, false, true];
    }

    /// Chapter two: one measured booking, decoded as (provider, room, start slot).
    operation SampleLocation() : (Int, Int, Int) {
        // Destructure the tuple into the four independent inputs to the oracle.
        let (providerFree, subLocationFree, qualified, suitable) = BusyLocationTables();
        // Two consecutive slots must be available; the search may still measure an infeasible result.
        let index = LocationSearch.FindBooking(providerFree, subLocationFree, qualified, suitable, 2);
        // Provider bits are lowest, then room bits, then time bits: undo that packing.
        return LocationSearch.Decode(index, Length(providerFree), Length(subLocationFree));
    }

    /// Mirrors the quantum inputs in samples/location.json; names are host-only labels.
    function BusyLocationTables() : (Bool[][], Bool[][], Bool[], Bool[]) {
        // Rows are providers. Columns are 09:00, 10:00, ..., 16:00; true means free.
        let providerFree = [
            [true, false, true, true, false, false, true, true],   // Avery
            [false, false, false, true, true, true, false, false], // Blake
            [true, true, false, false, true, true, true, false],   // Casey
            [false, true, true, false, false, true, true, true]    // Drew
        ];
        // The same columns, now one availability row per room/sub-location.
        let subLocationFree = [
            [true, true, false, false, true, true, true, true],    // Suite A
            [false, true, true, true, false, false, true, true],   // Suite B
            [true, false, true, true, true, false, false, true],   // Suite C
            [true, true, true, true, true, true, true, true]       // Suite D
        ];
        let qualified = [true, true, false, true]; // Casey (index 2) cannot perform this service.
        let suitable = [true, true, true, false];  // Suite D (index 3) lacks the equipment.
        return (providerFree, subLocationFree, qualified, suitable); // Bundle the four inputs, without copying answers.
    }

    /// Chapter four: a quiet day with only two zero-loose-end placements.
    /// The search is probabilistic. (-1, -1, -1) means the budget found nothing.
    operation SamplePlacement() : (Int, Int, Int) {
        let (providerFree, subLocationFree, qualified, suitable) = QuietLocationTables(); // Read the quiet-day inputs.
        let total = Length(providerFree) * Length(subLocationFree) * Length(providerFree[0]); // All possible triples.
        let budget = EarliestSearch.DurrHoyerBudget(total); // A demonstration cap, not a success guarantee.
        // `_` discards the three work counters; the Python and C# hosts display them instead.
        let (index, _, _, _) = PlacementSearch.BestPlacement(providerFree, subLocationFree, qualified, suitable, 2, budget);
        if index < 0 { // Do not try to decode the no-result sentinel as a booking.
            return (-1, -1, -1);
        }
        return LocationSearch.Decode(index, Length(providerFree), Length(subLocationFree)); // Unpack the verified result.
    }

    /// Mirrors the quantum inputs in samples/location-quiet.json.
    function QuietLocationTables() : (Bool[][], Bool[][], Bool[], Bool[]) {
        // Provider rows use the same order and hourly columns as the busy day.
        let providerFree = [
            [true, true, true, true, true, true, true, true],    // Avery: free all day.
            [true, true, true, false, true, true, true, true],   // Blake: booked at 12:00.
            [true, true, true, true, true, true, true, true],    // Casey: free, but still unqualified.
            [false, false, true, true, true, true, true, true]  // Drew: booked until 11:00.
        ];
        let subLocationFree = [
            [true, true, true, true, true, true, true, true],    // Suite A: free all day.
            [true, true, true, true, true, true, true, true],    // Suite B: free all day.
            [true, true, false, false, true, true, true, true],  // Suite C: booked 11:00 to 13:00.
            [true, true, true, true, true, true, true, true]     // Suite D: free, but still unsuitable.
        ];
        let qualified = [true, true, false, true]; // Qualification is independent of availability.
        let suitable = [true, true, true, false];  // Equipment is independent of availability too.
        return (providerFree, subLocationFree, qualified, suitable); // Return inputs for both the demo and drift check.
    }
}
