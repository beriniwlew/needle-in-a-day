namespace QuantumBooking;

/// <summary>
/// One day at a location, as the inputs to a booking search.
/// </summary>
/// <remarks>
/// <para>
/// Everything the quantum oracle needs is here and nothing else: who is free
/// when (<see cref="ProviderFree"/>, one row per provider, one entry per slot),
/// which sub-locations are free when (<see cref="SubLocationFree"/>, one row per
/// sub-location), which providers offer the service (<see cref="Qualified"/>)
/// and which sub-locations suit it (<see cref="Suitable"/>). The three name
/// lists exist only so results can be printed for a human.
/// </para>
/// <para>
/// No sample data lives in this type. Sample locations are JSON files under
/// <c>samples/</c>, read with <see cref="LocationFile.Read"/>, and the same
/// files feed the Python host, so every host sees one set of data.
/// </para>
/// <para>
/// The collection types are chosen to match what CSnakes generates from the
/// Python hints <c>list[list[bool]]</c> and <c>list[bool]</c>, so a location
/// can be handed straight to the Python bridge without any conversion. They
/// are also what System.Text.Json binds JSON arrays to, so the record is
/// deserialised through its constructor with no extra mapping code.
/// </para>
/// <para>
/// Every count must be a power of two. Each dimension becomes a register of
/// qubits, and a register of n qubits names exactly 2^n indices. A count of
/// three would leave one basis state naming nothing, and the uniform
/// superposition that starts Grover's search would waste amplitude on it.
/// </para>
/// </remarks>
public sealed record Location(
    IReadOnlyList<string> Providers,
    IReadOnlyList<string> SubLocations,
    IReadOnlyList<string> Slots,
    IReadOnlyList<IReadOnlyList<bool>> ProviderFree,
    IReadOnlyList<IReadOnlyList<bool>> SubLocationFree,
    IReadOnlyList<bool> Qualified,
    IReadOnlyList<bool> Suitable)
{
    /// <summary>The size of the search space: every (provider, sub-location, slot) triple, feasible or not.</summary>
    public int States => Providers.Count * SubLocations.Count * Slots.Count;

    /// <summary>Qubits in the index register: log2 of each count, added, because the registers sit side by side.</summary>
    public int Qubits => Log2(Providers.Count) + Log2(SubLocations.Count) + Log2(Slots.Count);

    /// <summary>Throws when a count is not a power of two or a table has the wrong shape.</summary>
    public void Validate()
    {
        Require(IsPowerOfTwo(Providers.Count), "The number of providers must be a power of two.");
        Require(IsPowerOfTwo(SubLocations.Count), "The number of sub-locations must be a power of two.");
        Require(IsPowerOfTwo(Slots.Count) && Slots.Count >= 2, "The number of slots must be a power of two, at least 2.");
        Require(ProviderFree.Count == Providers.Count && ProviderFree.All(row => row.Count == Slots.Count),
            "ProviderFree needs one row per provider and one entry per slot.");
        Require(SubLocationFree.Count == SubLocations.Count && SubLocationFree.All(row => row.Count == Slots.Count),
            "SubLocationFree needs one row per sub-location and one entry per slot.");
        Require(Qualified.Count == Providers.Count, "Qualified needs one flag per provider.");
        Require(Suitable.Count == SubLocations.Count, "Suitable needs one flag per sub-location.");
    }

    // A power of two has exactly one bit set, so clearing its lowest set bit leaves zero.
    private static bool IsPowerOfTwo(int n) => n >= 1 && (n & (n - 1)) == 0;

    // For a power of two, the number of trailing zero bits is its base-2 logarithm.
    private static int Log2(int powerOfTwo) => int.TrailingZeroCount(powerOfTwo);

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new ArgumentException(message);
        }
    }
}
