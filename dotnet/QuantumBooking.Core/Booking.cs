namespace QuantumBooking;

/// <summary>
/// A provider, a sub-location and a start slot, as indices into a <see cref="Location"/>.
/// </summary>
/// <remarks>
/// The quantum register is laid out as provider bits, then sub-location bits, then
/// slot bits, each little-endian. Read as a single little-endian integer the
/// register equals p + P·s + P·S·t, a mixed-radix number whose "digits" are the
/// three indices. <see cref="Encode"/> and <see cref="Decode"/> are that
/// packing and its inverse, and must match <c>LocationSearch.Decode</c> in Q# and
/// <c>decode</c> in location.py exactly, or the hosts would mislabel results.
/// Worked example with P = S = 4: Drew (3) in Suite A (0) at 15:00 (slot 6) is
/// 3 + 4·0 + 16·6 = 99, in binary 110 00 11: slot, sub-location, provider.
/// </remarks>
public readonly record struct Booking(int Provider, int SubLocation, int Slot)
{
    /// <summary>Packs the booking the way the Q# register reads it: p + P·s + P·S·t.</summary>
    public int Encode(Location location)
        => Provider + location.Providers.Count * (SubLocation + location.SubLocations.Count * Slot);

    /// <summary>
    /// The inverse of <see cref="Encode"/>, applied to a measured register value:
    /// the provider is the remainder modulo P, the sub-location is the next digit in
    /// base R, and the slot is what remains.
    /// </summary>
    public static Booking Decode(int index, Location location)
    {
        var providers = location.Providers.Count;
        var subLocations = location.SubLocations.Count;
        return new Booking(index % providers, index / providers % subLocations, index / (providers * subLocations));
    }

    /// <summary>A human-readable form, for example "Drew in Suite A at 15:00".</summary>
    public string Describe(Location location)
        => $"{location.Providers[Provider]} in {location.SubLocations[SubLocation]} at {location.Slots[Slot]}";
}
