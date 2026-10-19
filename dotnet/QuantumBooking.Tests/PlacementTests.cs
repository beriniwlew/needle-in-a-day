namespace QuantumBooking.Tests;

/// <summary>
/// Chapter four's classical score, pinned on both sample locations. The quiet
/// day is the one the chapter runs on, because on the busy day most bookings
/// already sit snug and the minimum is found on the first try.
/// </summary>
[TestFixture]
public sealed class PlacementTests
{
    private static readonly Location Busy = LocationFile.Read(SamplePaths.Location);
    private static readonly Location Quiet = LocationFile.Read(SamplePaths.QuietLocation);

    [Test]
    public void Quiet_day_has_45_feasible_two_slot_bookings_scored_2_22_21()
    {
        var feasible = ClassicalSearch.Feasible(Quiet, durationSlots: 2);
        var byScore = feasible.GroupBy(b => ClassicalSearch.LooseEnds(Quiet, 2, b)).ToDictionary(g => g.Key, g => g.Count());

        Assert.Multiple(() =>
        {
            Assert.That(feasible, Has.Count.EqualTo(45));
            Assert.That(byScore[0], Is.EqualTo(2), "flush on both sides");
            Assert.That(byScore[1], Is.EqualTo(22), "one scrap of free time left");
            Assert.That(byScore[2], Is.EqualTo(21), "floating in free time");
        });
    }

    [Test]
    public void Only_Avery_and_Blake_in_Suite_C_at_nine_leave_no_loose_ends_on_the_quiet_day()
    {
        var snug = ClassicalSearch.Feasible(Quiet, 2).Where(b => ClassicalSearch.LooseEnds(Quiet, 2, b) == 0).ToList();

        Assert.That(snug, Is.EquivalentTo(new[] { new Booking(0, 2, 0), new Booking(1, 2, 0) }));
    }

    // Busy day: eight of the ten two-slot bookings already sit snug; Drew's two in Suite A each leave one loose end.
    [TestCase(0, 0, 6, 0)] // Avery, Suite A, 15:00: Avery is busy before, the day ends after
    [TestCase(3, 0, 5, 1)] // Drew, Suite A, 14:00: 16:00 is free for both, a scrap after
    [TestCase(3, 0, 6, 1)] // Drew, Suite A, 15:00: 14:00 is free for both, a scrap before
    public void Loose_ends_on_the_busy_day_match_the_hand_count(int provider, int subLocation, int slot, int expected)
        => Assert.That(ClassicalSearch.LooseEnds(Busy, 2, new Booking(provider, subLocation, slot)), Is.EqualTo(expected));
}
