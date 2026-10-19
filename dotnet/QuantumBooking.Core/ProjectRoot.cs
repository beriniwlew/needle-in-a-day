namespace QuantumBooking;

/// <summary>
/// Locates the folder that holds <c>qsharp.json</c>: the Q# project root, the
/// Python home the C# host configures, and the parent of <c>samples/</c>.
/// </summary>
public static class ProjectRoot
{
    /// <summary>
    /// Walks up from the running binary until <c>qsharp.json</c> appears. The
    /// binary lives in <c>dotnet/&lt;project&gt;/bin/&lt;Configuration&gt;/net10.0/</c>,
    /// so the root is a few levels up; walking keeps this independent of the
    /// exact depth and of the working directory the process was started from.
    /// Both the Host and the tests use it, which is why it lives in Core.
    /// </summary>
    public static string Find()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "qsharp.json")))
            {
                return dir.FullName;
            }
        }

        throw new InvalidOperationException("Could not find qsharp.json above the executable; run from inside the project folder.");
    }
}
