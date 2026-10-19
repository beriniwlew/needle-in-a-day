namespace QuantumBooking.Tests;

/// <summary>
/// The sample files are shared with the Python hosts and mirrored by hand in
/// src/Samples.qs, so their shape is pinned here: a change to the data should
/// be a deliberate one, made in all three places.
/// </summary>
[TestFixture]
public sealed class SampleFilesTests
{
    [Test]
    public void Location_sample_loads_validates_and_names_the_two_excluded_resources()
    {
        var location = LocationFile.Read(SamplePaths.Location);

        Assert.Multiple(() =>
        {
            Assert.That(location.Providers, Is.EqualTo(new[] { "Avery", "Blake", "Casey", "Drew" }));
            Assert.That(location.SubLocations, Is.EqualTo(new[] { "Suite A", "Suite B", "Suite C", "Suite D" }));
            Assert.That(location.Slots, Has.Count.EqualTo(8).And.Contains("09:00").And.Contains("16:00"));
            Assert.That(location.Qualified[2], Is.False, "Casey does not offer the service");
            Assert.That(location.Suitable[3], Is.False, "Suite D lacks the equipment");
        });
    }

    [Test]
    public void Quiet_location_sample_loads_and_has_the_three_bookings_the_description_names()
    {
        var quiet = LocationFile.Read(SamplePaths.QuietLocation);

        Assert.Multiple(() =>
        {
            Assert.That(quiet.States, Is.EqualTo(128));
            Assert.That(quiet.ProviderFree[1][3], Is.False, "Blake is booked at 12:00");
            Assert.That(quiet.ProviderFree[3].Take(2), Is.All.False, "Drew is booked until 11:00");
            Assert.That(quiet.SubLocationFree[2].Skip(2).Take(2), Is.All.False, "Suite C is booked from 11:00 to 13:00");
        });
    }

    [Test]
    public void Days_sample_has_three_eight_slot_days_starting_at_nine()
    {
        var file = DayFile.Read(SamplePaths.Days);

        Assert.Multiple(() =>
        {
            Assert.That(file.DayStartHour, Is.EqualTo(9));
            Assert.That(file.Days.Select(d => d.Name), Is.EqualTo(new[] { "one opening", "three openings", "fully booked" }));
            Assert.That(file.Days, Is.All.Matches<Day>(d => d.Free.Count == 8));
            Assert.That(file.Days[1].Free.Count(f => f), Is.EqualTo(3), "the three-openings day is also Samples.Main in Q#");
            Assert.That(file.Days[2].Free, Is.All.False);
        });
    }
}
