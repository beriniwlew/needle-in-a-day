namespace QuantumBooking.Tests;

/// <summary>
/// Pins the iteration counts and success probabilities the README quotes, for
/// both chapters: eight slots for one provider's day, and the 128-state
/// location with its 26 one-slot and 10 two-slot feasible bookings.
/// </summary>
[TestFixture]
public sealed class GroverMathTests
{
    [TestCase(8, 1, 2, 0.9453)]
    [TestCase(8, 2, 1, 1.0000)]
    [TestCase(8, 3, 1, 0.8438)]
    [TestCase(8, 4, 0, 0.5000)]
    [TestCase(16, 9, 0, 0.5625)]
    [TestCase(8, 8, 0, 1.0000)]
    [TestCase(128, 26, 1, 0.9720)]
    [TestCase(128, 10, 2, 0.9764)]
    public void Iterations_and_success_probability_match_the_README_table(int total, int marked, int iterations, double probability)
    {
        Assert.That(GroverMath.Iterations(total, marked), Is.EqualTo(iterations));
        Assert.That(GroverMath.SuccessProbability(total, marked), Is.EqualTo(probability).Within(0.0001));
    }

    [Test]
    public void Default_demonstration_budget_for_the_sample_location_is_324()
        => Assert.That(GroverMath.DurrHoyerBudget(128), Is.EqualTo(324));

    [Test]
    public void Nothing_marked_is_rejected()
        => Assert.That(() => GroverMath.Iterations(8, 0), Throws.TypeOf<ArgumentOutOfRangeException>());

    [Test]
    public void Chosen_iterations_never_reduce_the_uniform_success_probability()
    {
        foreach (var total in new[] { 2, 4, 8, 16, 32, 64, 128 })
        {
            for (var marked = 1; marked <= total; marked++)
            {
                var theta = Math.Asin(Math.Sqrt((double)marked / total));
                var amplitude = Math.Sin((2 * GroverMath.Iterations(total, marked) + 1) * theta);
                Assert.That(amplitude * amplitude + 1e-12, Is.GreaterThanOrEqualTo((double)marked / total),
                    $"N={total}, M={marked}");
            }
        }
    }
}
