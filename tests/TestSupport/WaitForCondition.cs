using System;
using System.Threading;
using System.Threading.Tasks;

/// <summary>
/// Tiny polling helper that replaces ad-hoc <c>while (!cond) await Task.Delay(10)</c>
/// loops in async tests. Polls a predicate at a fixed interval until it returns
/// true or the timeout elapses. Returns the final value so callers can either
/// branch or assert on it.
/// </summary>
internal static class WaitForCondition
{
    /// <summary>
    /// Poll <paramref name="predicate"/> every <paramref name="pollInterval"/> (default 10 ms)
    /// up to <paramref name="timeout"/> (default 5 s). Returns true if the predicate became
    /// true within the timeout, false otherwise.
    /// </summary>
    public static async Task<bool> WaitForAsync(
        Func<bool> predicate,
        TimeSpan? timeout = null,
        TimeSpan? pollInterval = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(predicate);
        var effectiveTimeout = timeout ?? TimeSpan.FromSeconds(5);
        var effectivePoll = pollInterval ?? TimeSpan.FromMilliseconds(10);

        using var timeoutCts = new CancellationTokenSource(effectiveTimeout);
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token);

        while (!predicate())
        {
            try
            {
                await Task.Delay(effectivePoll, linkedCts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                if (cancellationToken.IsCancellationRequested)
                {
                    throw;
                }
                // Timeout fired — predicate never became true within the budget.
                return predicate();
            }
        }
        return true;
    }
}
