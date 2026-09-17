-- Key chords handled by the plugin instead of the terminal.
--
-- on_key(key, ctrl, shift, alt, super) is called for every named key press
-- while a terminal is focused. Return an action name, or nil to send the key
-- to the terminal. Available actions:
--   "toggle"     show/hide the drop-down
--   "copy"       copy the mouse selection (drag, double-click word, triple-click line)
--   "paste"      paste the clipboard (bracketed when the app asks for it)
--   "new_tab"    open a new tab with the default profile
--   "close_tab"  close the current tab
--   "next_tab" / "prev_tab"
--   "scroll_up" / "scroll_down" / "scroll_bottom"
--   "font_bigger" / "font_smaller" / "font_reset"   (ctrl+= ctrl+- ctrl+0, ctrl+wheel)
--   "profile:<n>" open a new tab with profile n

local M = {}

function M.on_key(key, ctrl, shift, alt, super)
  if ctrl and shift then
    if key == 'c' then return 'copy' end
    if key == 'v' then return 'paste' end
    if key == 't' then return 'new_tab' end
    if key == 'w' then return 'close_tab' end
    if key == 'tab' then return 'prev_tab' end
    if key == 'equal' then return 'font_bigger' end
    if key == 'minus' then return 'font_smaller' end
  end
  if ctrl and not shift then
    if key == 'insert' then return 'copy' end
    if key == 'equal' then return 'font_bigger' end
    if key == 'minus' then return 'font_smaller' end
    if key == '0' then return 'font_reset' end
    if key == 'tab' then return 'next_tab' end
    if key == 'pageup' then return 'prev_tab' end
    if key == 'pagedown' then return 'next_tab' end
  end
  if shift and not ctrl then
    if key == 'pageup' then return 'scroll_up' end
    if key == 'pagedown' then return 'scroll_down' end
    if key == 'insert' then return 'paste' end
  end
  if key == 'escape' and shift then return 'toggle' end
  -- The dropdown and world toggle chords (toggle_mods / world_toggle_mods + `)
  -- are matched by the core before this is asked, so they follow the settings.
  return nil
end

return M
