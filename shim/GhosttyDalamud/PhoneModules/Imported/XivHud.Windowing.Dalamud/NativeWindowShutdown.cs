namespace XivHud.Windowing.Dalamud;

/// <summary>Retains every asynchronous native retirement until the consumer unloads.</summary>
internal sealed class NativeWindowShutdown
{
    private readonly object gate = new();
    private Task completion = Task.CompletedTask;

    public Task Completion { get { lock (gate) return completion; } }

    public void Track(Task retirement)
    {
        ArgumentNullException.ThrowIfNull(retirement);
        lock (gate)
        {
            // Successful completed generations need no further storage. Pending or
            // failed retirements remain part of the unload barrier, including faults.
            completion = completion.IsCompletedSuccessfully
                ? retirement : Task.WhenAll(completion, retirement);
        }
    }
}
