using Microsoft.Extensions.Logging;

namespace VoxFlow.Core.Logging;

/// <summary>
/// Minimal host logger provider for local command-line style processes that
/// need deterministic plain-text output without adding a logging formatter
/// dependency.
/// </summary>
public sealed class TextWriterLoggerProvider : ILoggerProvider
{
    private readonly TextWriter _writer;
    private readonly LogLevel _minimumLevel;
    private readonly object _sync = new();

    public TextWriterLoggerProvider(TextWriter writer, LogLevel minimumLevel = LogLevel.Information)
    {
        ArgumentNullException.ThrowIfNull(writer);
        _writer = writer;
        _minimumLevel = minimumLevel;
    }

    public ILogger CreateLogger(string categoryName)
        => new TextWriterLogger(_writer, _minimumLevel, _sync);

    public void Dispose()
    {
    }

    private sealed class TextWriterLogger : ILogger
    {
        private readonly TextWriter _writer;
        private readonly LogLevel _minimumLevel;
        private readonly object _sync;

        public TextWriterLogger(TextWriter writer, LogLevel minimumLevel, object sync)
        {
            _writer = writer;
            _minimumLevel = minimumLevel;
            _sync = sync;
        }

        public IDisposable? BeginScope<TState>(TState state)
            where TState : notnull
            => NullScope.Instance;

        public bool IsEnabled(LogLevel logLevel)
            => logLevel != LogLevel.None && logLevel >= _minimumLevel;

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

            lock (_sync)
            {
                if (!string.IsNullOrWhiteSpace(message))
                {
                    _writer.WriteLine(message);
                }

                if (exception is not null)
                {
                    _writer.WriteLine($"{exception.GetType().Name}: {exception.Message}");
                }

                _writer.Flush();
            }
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
