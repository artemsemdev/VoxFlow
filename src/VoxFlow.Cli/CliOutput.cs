namespace VoxFlow.Cli;

internal static class CliOutput
{
    public static TextWriter Error => Console.Error;

    public static bool IsOutputRedirected => Console.IsOutputRedirected;

    public static int WindowWidth => Console.WindowWidth;

    public static void Write(string value)
        => Console.Out.Write(value);

    public static void WriteLine()
        => Console.Out.Write(Environment.NewLine);

    public static void WriteLine(string value)
        => Console.Out.Write(value + Environment.NewLine);

    public static void WriteErrorLine(string value)
        => Console.Error.Write(value + Environment.NewLine);
}
