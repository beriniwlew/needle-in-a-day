namespace QuantumBooking.Tests;

/// <summary>
/// The packing between a (provider, sub-location, slot) triple and the integer the
/// quantum register measures to. A mismatch here would make the host label the
/// right answers as wrong, so the layout is pinned with a worked example.
/// </summary>
[TestFixture]
public sealed class BookingTests
{
    private static readonly Location Sample = LocationFile.Read(SamplePaths.Location);

    [Test]
    public void Encode_then_decode_round_trips_every_state()
    {
        for (var index = 0; index < Sample.States; index++)
        {
            var booking = Booking.Decode(index, Sample);
            Assert.That(booking.Encode(Sample), Is.EqualTo(index));
        }
    }

    [Test]
    public void Encoding_matches_the_register_layout_provider_bits_lowest()
    {
        // p + P·s + P·S·t with P = S = 4: Drew (3) in Suite A (0) at 15:00 (slot 6) is 3 + 0 + 96.
        Assert.That(new Booking(3, 0, 6).Encode(Sample), Is.EqualTo(99));
        Assert.That(new Booking(3, 0, 6).Describe(Sample), Is.EqualTo("Drew in Suite A at 15:00"));
    }
}
