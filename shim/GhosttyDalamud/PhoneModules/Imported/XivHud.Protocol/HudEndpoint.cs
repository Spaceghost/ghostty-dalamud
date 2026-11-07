using System.Text.Json;

namespace XivHud.Protocol;

/// <summary>Reads immutable snapshots on any thread; changes run only when the owner drains its queue.</summary>
public sealed class HudEndpoint(string module) : IDisposable
{
    private readonly object gate = new();
    private readonly Queue<(string Id, HudCommand Command)> pending = new();
    private readonly Dictionary<string, object> results = new(StringComparer.Ordinal);
    private readonly Queue<string> completed = new();
    private string snapshot = "{}";
    private bool disposed;
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    public void Publish(object state)
    {
        var value = JsonSerializer.Serialize(new { version = 1, module, observedAt = DateTimeOffset.UtcNow, state }, Json);
        lock (gate) { if (!disposed) snapshot = value; }
    }

    public string Call(string input)
    {
        if (string.IsNullOrEmpty(input) || input.Length > 4096) return Error("invalid_request");
        try
        {
            using var doc = JsonDocument.Parse(input, new JsonDocumentOptions { MaxDepth = 8 });
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("method", out var m) || m.ValueKind != JsonValueKind.String)
                return Error("invalid_request");
            var method = m.GetString()!;
            var parameters = root.TryGetProperty("params", out var p) ? p.Clone() : JsonSerializer.SerializeToElement(new { });
            lock (gate)
            {
                if (disposed) return Error("unloaded");
                if (method == "api.version") return Ok(new { version = 1, module, methods = new[] { "api.version", "status", "request.status" }.Concat(HudCommands.Methods(module)) });
                if (method == "status") return "{\"ok\":true,\"result\":" + snapshot + "}";
                if (method == "request.status")
                {
                    if (parameters.ValueKind != JsonValueKind.Object || !parameters.TryGetProperty("id", out var id) || id.ValueKind != JsonValueKind.String)
                        return Error("invalid_request_id");
                    return results.TryGetValue(id.GetString()!, out var result) ? Ok(result) : Error("request_not_found");
                }
                var command = new HudCommand(method, parameters);
                if (HudCommands.Validate(module, command) is { } error) return Error(error);
                if (pending.Count >= 32) return Error("queue_full");
                var requestId = Guid.NewGuid().ToString("N");
                pending.Enqueue((requestId, command));
                results[requestId] = new { id = requestId, state = "queued", method };
                return Ok(new { accepted = true, requestId, state = "queued" });
            }
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or FormatException) { return Error("invalid_request"); }
    }

    /// <summary>Framework thread only. Success means applied by the module; read status to confirm actual presentation.</summary>
    public void Process(Func<HudCommand, string?> apply, Action<Exception>? onError = null)
    {
        for (var n = 0; n < 8; n++)
        {
            (string Id, HudCommand Command) request;
            lock (gate) { if (disposed || !pending.TryDequeue(out request)) return; }
            string? error;
            try { error = apply(request.Command); }
            catch (Exception e) { error = "operation_failed"; onError?.Invoke(e); }
            lock (gate)
            {
                if (disposed) return;
                results[request.Id] = new { id = request.Id, state = error is null ? "applied" : "refused", method = request.Command.Method, error };
                completed.Enqueue(request.Id);
                while (completed.Count > 64) results.Remove(completed.Dequeue());
            }
        }
    }

    public void Dispose() { lock (gate) { disposed = true; pending.Clear(); results.Clear(); completed.Clear(); snapshot = "{}"; } }
    private static string Ok(object value) => JsonSerializer.Serialize(new { ok = true, result = value }, Json);
    private static string Error(string error) => JsonSerializer.Serialize(new { ok = false, error }, Json);
}
