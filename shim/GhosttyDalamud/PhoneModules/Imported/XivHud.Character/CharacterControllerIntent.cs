namespace XivHud.Character;

public enum CharacterControllerCommand
{
    Up, Down, Left, Right, PreviousTab, NextTab, Scroll, Confirm, Back,
    Secondary, NativeDetails, Appearance, Armoury,
}
public readonly record struct CharacterControllerIntent(CharacterControllerCommand Command, float Amount = 1);
