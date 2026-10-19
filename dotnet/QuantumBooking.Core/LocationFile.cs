using System.Text.Json;

namespace QuantumBooking;

/// <summary>
/// Reads a <see cref="Location"/> from a JSON file such as <c>samples/location.json</c>.
/// </summary>
/// <remarks>
/// The JSON keys are the record's constructor parameters in camelCase
/// (<c>providers</c>, <c>subLocations</c>, <c>slots</c>, <c>providerFree</c>,
/// <c>subLocationFree</c>, <c>qualified</c>, <c>suitable</c>). System.Text.Json
/// binds them to the positional record's constructor, which is why the record
/// needs no attributes. Extra keys such as <c>description</c> are ignored, so
/// the files can carry notes for humans. The result is validated before it is
/// returned, so a malformed sample fails here with a clear message rather than
/// deep inside the search.
/// </remarks>
public static class LocationFile
{
    // Web defaults: camelCase property names and case-insensitive matching.
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);

    public static Location Read(string path)
    {
        var location = JsonSerializer.Deserialize<Location>(File.ReadAllText(path), Options)
            ?? throw new InvalidDataException($"{path} does not contain a location.");
        location.Validate();
        return location;
    }
}
