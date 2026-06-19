using Microsoft.Extensions.Logging;

namespace VoxFlow.Desktop.Services;

internal sealed class DesktopDiagnosticsLoggerProvider : ILoggerProvider
{
    public ILogger CreateLogger(string categoryName)
        => new DesktopDiagnosticsLogger(categoryName);

    public void Dispose()
    {
    }

    private sealed class DesktopDiagnosticsLogger : ILogger
    {
        private readonly string _categoryName;

        public DesktopDiagnosticsLogger(string categoryName)
        {
            _categoryName = categoryName;
        }

        public IDisposable? BeginScope<TState>(TState state)
            where TState : notnull
            => NullScope.Instance;

        public bool IsEnabled(LogLevel logLevel)
            => logLevel != LogLevel.None;

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            ArgumentNullException.ThrowIfNull(formatter);

            if (!IsEnabled(logLevel))
            {
                return;
            }

            var message = formatter(state, exception);
            if (string.IsNullOrWhiteSpace(message) && exception is null)
            {
                return;
            }

            var context = $"{logLevel}: {_categoryName}";
            if (exception is not null)
            {
                DesktopDiagnostics.LogException(
                    string.IsNullOrWhiteSpace(message) ? context : $"{context}: {message}",
                    exception);
                return;
            }

            DesktopDiagnostics.LogInfo($"{context}: {message}");
        }
    }

    private sealed class NullScope : IDisposable
    {
        public static readonly NullScope Instance = new();

        private NullScope()
        {
        }

        public void Dispose()
        {
        }
    }
}
