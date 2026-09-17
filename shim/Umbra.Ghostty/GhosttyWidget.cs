// Toolbar widget + popup for the Ghostty terminal. The terminal itself lives
// in the GhosttyDalamud plugin; everything here goes through GhosttyIpc.
using System.Collections.Generic;
using Dalamud.Bindings.ImGui;
using Umbra.Widgets;
using Una.Drawing;

namespace Umbra.Ghostty;

[ToolbarWidget("Ghostty", "Ghostty terminal", "Status and a popup terminal from the Ghostty plugin. Press ctrl+` for the drop-down.")]
public class GhosttyWidget(
    WidgetInfo                  info,
    string?                     guid         = null,
    Dictionary<string, object>? configValues = null
) : StandardToolbarWidget(info, guid, configValues)
{
    protected override StandardWidgetFeatures Features =>
        StandardWidgetFeatures.Text | StandardWidgetFeatures.Icon | StandardWidgetFeatures.CustomizableIcon;

    public override WidgetPopup Popup { get; } = new GhosttyPopup();

    protected override void OnLoad()
    {
        SetGameIconId(60071);
    }

    protected override void OnDraw()
    {
        // also tells the plugin the widget is on screen (its info bar entry steps aside)
        SetText(GhosttyIpc.Status());
    }
}

public sealed class GhosttyPopup : WidgetPopup
{
    protected override Node Node { get; } = new GhosttyNode();
    protected override void OnOpen() => ((GhosttyNode)Node).Resize();
}

public sealed unsafe class GhosttyNode : Node
{
    public GhosttyNode()
    {
        Style = new Style { Size = new Size(900, 480) };
    }

    public void Resize()
    {
        var (w, h) = GhosttyIpc.PopupSize();
        Style.Size = new Size(w, h);
    }

    protected override void OnDraw(ImDrawListPtr drawList)
    {
        var r = Bounds.ContentRect;
        GhosttyIpc.PopupDraw((nint)drawList.Handle, r.X1, r.Y1, r.X2, r.Y2);
    }
}
