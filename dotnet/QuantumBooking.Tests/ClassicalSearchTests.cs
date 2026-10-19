namespace QuantumBooking.Tests;

/// <summary>
/// Pins the classical reference. The quantum search is probabilistic and lives
/// behind an embedded Python runtime, so it is exercised by the hosts' --check
/// modes rather than here; these tests make sure the thing it is compared
/// against is right.
/// </summary>
[TestFixture]
public sealed class ClassicalSearchTests
{
    private static readonly Location Sample = LocationFile.Read(SamplePaths.Location);

    [Test]
    public void Sample_location_is_valid_and_sized_as_the_quantum_register_expects()
    {
        // 4 × 4 × 8 states on 2 + 2 + 3 qubits: the numbers the Q# and Python hosts print.
        Assert.DoesNotThrow(Sample.Validate);
        Assert.That(Sample.States, Is.EqualTo(128));
        Assert.That(Sample.Qubits, Is.EqualTo(7));
    }

    // The same two counts that location.py prints and LocationSearch.FeasibleCount returns.
    [TestCase(1, 26)]
    [TestCase(2, 10)]
    public void Feasible_count_matches_the_Q_sharp_and_Python_hosts(int durationSlots, int expected)
        => Assert.That(ClassicalSearch.Feasible(Sample, durationSlots), Has.Count.EqualTo(expected));

    [Test]
    public void Every_feasible_two_slot_booking_passes_the_check_and_none_uses_an_excluded_resource()
    {
        var feasible = ClassicalSearch.Feasible(Sample, durationSlots: 2);

        Assert.Multiple(() =>
        {
            Assert.That(feasible, Is.All.Matches<Booking>(b => ClassicalSearch.IsFeasible(Sample, 2, b)));
            Assert.That(feasible.Select(b => b.Provider), Has.None.EqualTo(2), "Casey is not qualified");
            Assert.That(feasible.Select(b => b.SubLocation), Has.None.EqualTo(3), "Suite D is not suitable");
            Assert.That(feasible, Does.Contain(new Booking(Provider: 3, SubLocation: 0, Slot: 6)), "Drew, Suite A, 15:00 fits two slots");
            Assert.That(feasible.Select(b => b.Slot), Has.None.EqualTo(7), "a two-slot service cannot start in the last slot");
        });
    }

    // Chapter three's classical reference. Two slots: Drew in Suite B at 10:00 (slot 1).
    // One slot: Avery in Suite A at 09:00, the first provider and suite free at slot 0.
    [TestCase(2, 3, 1, 1)]
    [TestCase(1, 0, 0, 0)]
    public void Earliest_feasible_booking_matches_the_hand_count(int durationSlots, int provider, int subLocation, int slot)
        => Assert.That(ClassicalSearch.Earliest(Sample, durationSlots), Is.EqualTo(new Booking(provider, subLocation, slot)));

    [Test]
    public void A_booking_that_runs_past_the_end_of_the_day_is_infeasible()
        => Assert.That(ClassicalSearch.IsFeasible(Sample, durationSlots: 2, new Booking(0, 0, 7)), Is.False);

    [Test]
    public void A_location_whose_counts_are_not_powers_of_two_is_rejected()
    {
        // Three sub-locations would need two qubits, whose fourth basis state names no sub-location.
        var threeSubLocations = Sample with
        {
            SubLocations = ["Suite A", "Suite B", "Suite C"],
            SubLocationFree = Sample.SubLocationFree.Take(3).ToList(),
            Suitable = [true, true, true],
        };

        Assert.That(threeSubLocations.Validate, Throws.ArgumentException);
    }
}
