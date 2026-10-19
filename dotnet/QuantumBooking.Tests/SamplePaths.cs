namespace QuantumBooking.Tests;

/// <summary>The sample files under samples/, found from the project root so the tests run from any working directory.</summary>
internal static class SamplePaths
{
    private static readonly string Samples = Path.Combine(ProjectRoot.Find(), "samples");

    public static string Location => Path.Combine(Samples, "location.json");

    public static string QuietLocation => Path.Combine(Samples, "location-quiet.json");

    public static string Days => Path.Combine(Samples, "days.json");
}
