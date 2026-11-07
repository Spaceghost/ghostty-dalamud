namespace XivHud.Journal;

public enum JournalControllerCommand
{
    Up, Down, Left, Right, PreviousTab, NextTab, Scroll, Confirm, Back,
    Bookmark, NativeDetails, Appearance, Search,
}
public readonly record struct JournalControllerIntent(JournalControllerCommand Command, float Amount = 1);

/// <summary>Pure state of the search keyboard; the final row always contains editing actions.</summary>
internal sealed class JournalSearchKeyboard
{
    private static readonly string[][][] Pages =
    [
        [ ["q","w","e","r","t","y","u","i","o","p"], ["a","s","d","f","g","h","j","k","l","'"],
          ["z","x","c","v","b","n","m","-",".","?"], ["Space","Backspace","Clear","Done"] ],
        [ ["1","2","3","4","5","6","7","8","9","0"], ["!","@","#","$","%","&","*","(",")","'"],
          ["é","è","ê","à","ç","ö","ü","ä","ß","-"], ["Space","Backspace","Clear","Done"] ],
    ];
    internal int Page { get; private set; }
    internal int Row { get; private set; }
    internal int Column { get; private set; }
    internal IReadOnlyList<string[]> Rows => Pages[Page];
    internal string Selected => Pages[Page][Row][Column];
    internal void Move(int dx, int dy)
    {
        var oldLength = Pages[Page][Row].Length;
        var nextRow = Math.Clamp(Row + dy, 0, Pages[Page].Length - 1);
        if (nextRow != Row)
            Column = Math.Min(Pages[Page][nextRow].Length - 1, (int)((Column + .5) / oldLength * Pages[Page][nextRow].Length));
        Row = nextRow;
        Column = Math.Clamp(Column + dx, 0, Pages[Page][Row].Length - 1);
    }
    internal void ChangePage(int direction) { Page = (Page + direction + Pages.Length) % Pages.Length; Column = Math.Min(Column, Pages[Page][Row].Length - 1); }
    internal void Select(int row, int column) { Row = row; Column = column; }
    internal static string Edit(string text, string key) => key switch
    {
        "Done" => text,
        "Clear" => "",
        "Backspace" => text.Length == 0 ? text : text[..System.Globalization.StringInfo.ParseCombiningCharacters(text)[^1]],
        "Space" => text.Length < 160 ? text + " " : text,
        _ => text.Length + key.Length <= 160 ? text + key : text,
    };
}
