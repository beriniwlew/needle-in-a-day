namespace QuantumBooking;

/// <summary>
/// The two numbers Grover's search is about, duplicated from the Q# functions
/// <c>SlotSearch.GroverIterations</c> and <c>SlotSearch.SuccessProbability</c>
/// so the C# host can print the theory without a round trip into Python, and
/// so the tests can pin the values the README quotes.
/// </summary>
/// <remarks>
/// Picture the state as an arrow in the plane spanned by "all good states" and
/// "all bad states". It starts at angle θ from the bad axis, where
/// sin²θ = M/N (M good states among N). Each round, an oracle call followed by
/// the diffusion operator, rotates the arrow by a further 2θ towards the good
/// axis. Measuring projects onto a good state with probability equal to the
/// squared component along the good axis, sin² of the current angle.
/// </remarks>
public static class GroverMath
{
    /// <summary>
    /// Choose the better integer on either side of the first probability peak,
    /// k = π/(4θ) − 1/2. Prefer fewer rounds on ties, including half marked.
    /// </summary>
    public static int Iterations(int total, int marked)
    {
        RequirePositive(total, marked);
        var theta = Math.Asin(Math.Sqrt((double)marked / total));
        var lower = Math.Max(0, (int)Math.Floor(Math.PI / (4 * theta) - 0.5));
        var upper = lower + 1;
        var lowerAmplitude = Math.Sin((2 * lower + 1) * theta);
        var upperAmplitude = Math.Sin((2 * upper + 1) * theta);
        return upperAmplitude * upperAmplitude > lowerAmplitude * lowerAmplitude + 1e-12 ? upper : lower;
    }

    /// <summary>
    /// sin²((2k+1)θ): the probability that one run returns a marked state after
    /// k rounds. With N = 8 this is 94.5% for one marked state, exactly 100% for
    /// two, 84.4% for three and 50% for four, where zero rounds is just as good
    /// as further Grover rotations and saves the oracle calls.
    /// </summary>
    public static double SuccessProbability(int total, int marked)
    {
        RequirePositive(total, marked);
        var theta = Math.Asin(Math.Sqrt((double)marked / total));
        var s = Math.Sin((2 * Iterations(total, marked) + 1) * theta);
        return s * s;
    }

    /// <summary>
    /// ceil(22.5·√N + 1.4·lg²N): a demonstration budget inspired by Dürr and
    /// Høyer's time bound. Our loop caps only Grover oracle calls and uses a
    /// sentinel threshold, so this is not a proven success bound for this variant.
    /// State preparation and classical candidate verification are additional work.
    /// </summary>
    public static int DurrHoyerBudget(int total)
    {
        if (total < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(total), "The search space must hold at least one state.");
        }

        var lg = Math.Log2(total);
        return (int)Math.Ceiling(22.5 * Math.Sqrt(total) + 1.4 * lg * lg);
    }

    // With nothing marked the oracle is the identity and the formulas divide by
    // zero; with everything marked there is nothing to search. Both are the
    // host's job to answer classically.
    private static void RequirePositive(int total, int marked)
    {
        if (marked < 1 || marked > total)
        {
            throw new ArgumentOutOfRangeException(nameof(marked), "Marked states must number between 1 and the total.");
        }
    }
}
