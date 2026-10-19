namespace QuantumBooking;

/// <summary>
/// The classical answer: a triple loop over provider, sub-location and start slot,
/// applying the same check the quantum oracle computes in superposition.
/// </summary>
/// <remarks>
/// <para>
/// This class plays two roles. It is the reference that the quantum histogram
/// is judged against, and it is the faster way to get the answer: a location with
/// ten providers, ten sub-locations and fifty slots has five thousand combinations,
/// which this loop finishes in microseconds. Grover's quadratic speedup only
/// pays off over spaces far too large to enumerate, and a location's day is not
/// one of them.
/// </para>
/// <para>
/// Its count is also what the search needs. The number of Grover iterations is
/// chosen using θ = asin(sqrt(M/N)), where M is the number of feasible bookings, so the
/// toy runs this loop first to tune the quantum search that then "finds" what
/// the loop already enumerated. The README calls this out as the shortcut it is.
/// </para>
/// </remarks>
public static class ClassicalSearch
{
    /// <summary>
    /// A booking is feasible when the provider is qualified, the sub-location is
    /// suitable, the service ends inside the day, and both the provider and
    /// the sub-location are free in every slot the service covers. This is the predicate
    /// the Q# oracle evaluates into ancilla qubits, written out plainly.
    /// </summary>
    public static bool IsFeasible(Location location, int durationSlots, Booking booking)
    {
        var (p, s, t) = booking;
        if (!location.Qualified[p] || !location.Suitable[s] || t + durationSlots > location.Slots.Count)
        {
            return false;
        }

        for (var k = 0; k < durationSlots; k++)
        {
            if (!location.ProviderFree[p][t + k] || !location.SubLocationFree[s][t + k])
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>
    /// The earliest feasible booking: among all feasible bookings, the one with
    /// the smallest slot, ties broken by provider then sub-location order. Null
    /// when nothing is feasible. This is the classical answer chapter three's
    /// minimum finding is compared against: N checks, no randomness, no budget.
    /// </summary>
    public static Booking? Earliest(Location location, int durationSlots)
    {
        var feasible = Feasible(location, durationSlots);
        return feasible.Count == 0 ? null : feasible.MinBy(b => b.Slot);
    }

    /// <summary>
    /// Chapter four's score: how many of the booking's two neighbouring slots,
    /// the one before it and the one after the service, are free for both the
    /// provider and the sub-location. Each such slot is a scrap of free time the
    /// booking would leave behind. Zero means the booking sits flush against
    /// other bookings or the edges of the day, which is what an "optimised"
    /// placement policy prefers. The Q# oracle computes the same two bits in
    /// superposition; this is the plain version the hosts score all N with.
    /// </summary>
    public static int LooseEnds(Location location, int durationSlots, Booking booking)
    {
        var (p, s, t) = booking;
        var ends = 0;
        if (t > 0 && location.ProviderFree[p][t - 1] && location.SubLocationFree[s][t - 1])
        {
            ends++;
        }

        var after = t + durationSlots;
        if (after < location.Slots.Count && location.ProviderFree[p][after] && location.SubLocationFree[s][after])
        {
            ends++;
        }

        return ends;
    }

    /// <summary>Every feasible booking, in provider, sub-location, slot order.</summary>
    public static IReadOnlyList<Booking> Feasible(Location location, int durationSlots)
    {
        location.Validate();
        if (durationSlots < 1 || durationSlots > location.Slots.Count)
        {
            throw new ArgumentOutOfRangeException(nameof(durationSlots), "A service spans between 1 slot and the whole day.");
        }

        var found = new List<Booking>();
        for (var p = 0; p < location.Providers.Count; p++)
        {
            for (var s = 0; s < location.SubLocations.Count; s++)
            {
                for (var t = 0; t < location.Slots.Count; t++)
                {
                    var booking = new Booking(p, s, t);
                    if (IsFeasible(location, durationSlots, booking))
                    {
                        found.Add(booking);
                    }
                }
            }
        }

        return found;
    }
}
