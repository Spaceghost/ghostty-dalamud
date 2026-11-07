using System.Numerics;
using System.Text.Json;
using Dalamud.Bindings.ImGui;

namespace XivSpell;

internal sealed partial class Plugin
{
    private bool editorOpen, editorSaving, editorCloseAfterSave, editorFocus;
    private string editorCard = "", editorSource = "", editorSavedSource = "", editorSubmittedSource = "";
    private string editorTicket = "", editorCommand = "", editorMessage = "";
    private long editorSaveAt;
    private bool editorDirty => editorSource != editorSavedSource;

    private void OpenSpellEditor(string id)
    {
        id = id.Trim();
        var resolved = ResolveRune(id)?.CardId ?? id;
        var card = cards.FirstOrDefault(c => c.Id.Equals(resolved, StringComparison.OrdinalIgnoreCase) ||
            c.Phrase.Equals(id, StringComparison.OrdinalIgnoreCase) || c.Name.Equals(id, StringComparison.OrdinalIgnoreCase));
        if (card == null) { weave.Hint = "Unknown spell · :ls lists the spellbook"; return; }
        editorFocus = true;
        if (editorSaving && editorCard != card.Id) { editorMessage = "Finish the current save before opening another spell"; return; }
        if (editorDirty && editorCard != card.Id) { editorOpen = true; editorMessage = "Save or revert the current spell before opening another."; return; }
        if (editorCard != card.Id || !editorDirty) {
            editorCard = card.Id; editorSource = editorSavedSource = card.Source; editorCommand = "";
            editorMessage = "Edit Lua · Ctrl+S saves · changes are validated before saving";
        }
        visible = false; editorOpen = true;
        InterruptWeave("Editing " + card.Name, true);
    }
    private void SaveSpellEditor(bool close = false)
    {
        if (!editorOpen) { weave.Hint = "Open a spell with :e first"; return; }
        if (editorSaving) return;
        editorSaving = true; editorCloseAfterSave = close; editorSubmittedSource = editorSource;
        editorTicket = Guid.NewGuid().ToString("N"); editorSaveAt = Environment.TickCount64;
        CardInput(JsonSerializer.Serialize(new { id = editorCard, source = editorSubmittedSource, original = editorSavedSource }), "editor-save", requestId: editorTicket);
        editorMessage = "Validating and saving…";
    }
    private void CloseSpellEditor()
    {
        if (editorSaving) { editorMessage = "Waiting for the save result…"; return; }
        if (editorDirty) { editorMessage = "Unsaved changes · save with :w, or Revert before closing"; return; }
        editorOpen = false;
    }
    private bool EditorTileCommand(string text)
    {
        var parts = text.Trim().Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return false;
        if (parts.Length > 1 && parts[0] is ":w" or ":write" or ":wq" or ":q" or ":quit") {
            editorMessage = weave.Hint = parts[0] + " takes no arguments"; return true;
        }
        switch (parts[0]) {
            case ":e": case ":edit":
                var selected = parts.Length > 1 ? parts[1] : weave.Runes.Count > 0 ? weave.Runes[Math.Min(weave.Cursor, weave.Runes.Count - 1)].CardId : "ruin";
                OpenSpellEditor(selected); return true;
            case ":w": case ":write": SaveSpellEditor(); return true;
            case ":wq": SaveSpellEditor(true); return true;
            case ":q": case ":quit": CloseSpellEditor(); return true;
        }
        return false;
    }
    private void DrawSpellEditor()
    {
        if (!editorOpen) return;
        if (editorSaving && Environment.TickCount64 - editorSaveAt > 8000) { editorSaving = false; editorMessage = "Save result unavailable · edits retained; reopen to check the file"; }
        var viewport = ImGui.GetMainViewport();
        ImGui.SetNextWindowSize(new(MathF.Min(700, viewport.Size.X - 40), MathF.Min(580, viewport.Size.Y - 80)), ImGuiCond.FirstUseEver);
        ImGui.SetNextWindowPos(new(viewport.Size.X * .52f, viewport.Size.Y * .1f), ImGuiCond.FirstUseEver, new(.5f, 0));
        if (editorFocus) ImGui.SetNextWindowFocus();
        ImGui.SetNextWindowBgAlpha(0);
        ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 1.5f);
        ImGui.PushStyleVar(ImGuiStyleVar.FrameBorderSize, 1f);
        ImGui.PushStyleColor(ImGuiCol.WindowBg, Vector4.Zero);
        ImGui.PushStyleColor(ImGuiCol.FrameBg, Vector4.Zero);
        ImGui.PushStyleColor(ImGuiCol.Border, new Vector4(.9f, .78f, .5f, .8f));
        ImGui.PushStyleColor(ImGuiCol.Text, new Vector4(.9f, .98f, 1, 1));
        if (ImGui.Begin("Grimoire · Spell editor###XivSpellEditor", ImGuiWindowFlags.NoCollapse | ImGuiWindowFlags.NoTitleBar)) {
            ImGui.SetWindowFontScale(1.1f);
            var card = cards.FirstOrDefault(c => c.Id == editorCard);
            var appearance = SpellAppearance.Resolve(data, card);
            if (appearance is { } visual && textures.GetFromGameIcon(visual.Icon).GetWrapOrDefault() is { } icon) {
                ImGui.Image(icon.Handle, new(42, 42)); ImGui.SameLine();
            }
            EditorLabel($"SPELL EDITOR / {card?.Name ?? editorCard}{(editorDirty ? " *" : "")}", new(1, .89f, .61f, 1));
            ImGui.Separator();
            var sourceId = ImGui.GetID("##spell-source");
            if (editorFocus) { ImGui.SetKeyboardFocusHere(); editorFocus = false; }
            ImGui.InputTextMultiline("##spell-source", ref editorSource, 16385, new(-1, MathF.Max(140, ImGui.GetContentRegionAvail().Y - 180)), ImGuiInputTextFlags.AllowTabInput);
            OutlineEditorSource(sourceId, editorSource);
            if (ImGui.Button(editorSaving ? "Saving…" : "Save · :w")) SaveSpellEditor();
            ImGui.SameLine(); if (ImGui.Button("Save + close · :wq")) SaveSpellEditor(true);
            ImGui.SameLine(); if (ImGui.Button("Revert") && !editorSaving) { editorSource = editorSavedSource; editorMessage = "Reverted unsaved changes"; }
            ImGui.SameLine(); if (ImGui.Button("Close · :q")) CloseSpellEditor();
            EditorLabel(editorMessage, new(.94f, .98f, 1, 1), true);
            EditorLabel(":e SPELL open · :w save · :wq save+close · :q close", new(1, .89f, .61f, 1));
            EditorLabel("COMMAND", new(1, .89f, .61f, 1));
            if (ImGui.InputText("##spell-editor-command", ref editorCommand, 256, ImGuiInputTextFlags.EnterReturnsTrue)) {
                if (!EditorTileCommand(editorCommand)) editorMessage = "Use :e SPELL, :w, :wq or :q";
                editorCommand = "";
            }
            if (ImGui.IsWindowFocused(ImGuiFocusedFlags.RootAndChildWindows) && ImGui.GetIO().KeyCtrl && ImGui.IsKeyPressed(ImGuiKey.S, false)) SaveSpellEditor();
        }
        ImGui.End(); ImGui.PopStyleColor(4); ImGui.PopStyleVar(2);
    }
}
