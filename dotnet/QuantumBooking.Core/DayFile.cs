using System.Text.Json;

namespace QuantumBooking;

/// <summary>One provider's day for chapter one: a name and one flag per hourly slot, true meaning free.</summary>
public sealed record Day(string Name, IReadOnlyList<bool> Free);

/// <summary>
/// A set of sample days such as <c>samples/days.json</c>: the hour slot 0
/// starts at, and the days themselves. The Python host reads the same file.
/// </summary>
public sealed record DayFile(int DayStartHour, IReadOnlyList<Day> Days)
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);

    public static DayFile Read(string path)
    {
        var file = JsonSerializer.Deserialize<DayFile>(File.ReadAllText(path), Options)
            ?? throw new InvalidDataException($"{path} does not contain sample days.");
        if (file.Days.Count == 0)
        {
            throw new InvalidDataException($"{path} lists no days.");
        }

        return file;
    }
}
