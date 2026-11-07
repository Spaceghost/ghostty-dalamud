-- Controller layouts for a focused terminal.
--
-- A mapping value is either a string or { action = string, repeat = boolean }.
-- Actions are terminal keys ("key:up", "key:enter", ...), literal input
-- ("text:...") or one of the actions documented in lua/keymap.lua.  Strings
-- repeat while held for key:/text: mappings and do not repeat for actions.
--
-- Add personal/community layouts without changing this shipped file:
--
--   local controllers = require('controllers')
--   controllers.add('my-layout', {
--     name = 'My layout', author = 'me', community = true,
--     mapping = { south = 'key:enter', east = 'key:escape' },
--   })
--
-- Then use controllers.config('my-layout') in init.lua, or add the layout to
-- CONFIG.controller.layouts before returning CONFIG.

local M = {}

local function binding(action, repeatable)
  return { action = action, ['repeat'] = repeatable }
end

M.layouts = {
  terminal = {
    name = 'Terminal (default)',
    description = 'Arrow keys, Enter/Escape, tabs, scrolling and clipboard.',
    mapping = {
      dpad_up = 'key:up', dpad_down = 'key:down',
      dpad_left = 'key:left', dpad_right = 'key:right',
      south = 'key:enter', east = 'key:escape', west = 'key:tab',
      north = 'key:space',
      l1 = 'prev_tab', r1 = 'next_tab',
      l2 = 'scroll_up', r2 = 'scroll_down',
      l3 = 'paste', r3 = 'scroll_bottom',
      start = binding('new_tab', false),
      -- select remains the global tap/hold/double-tap button by default.
    },
  },
  steamdeck = {
    name = 'Steam Deck',
    description = 'Deck-friendly terminal navigation; back buttons may be assigned through Steam Input.',
    mapping = {
      dpad_up = 'key:up', dpad_down = 'key:down',
      dpad_left = 'key:left', dpad_right = 'key:right',
      south = 'key:enter', east = 'key:escape', west = 'key:tab',
      north = 'key:space',
      l1 = 'prev_tab', r1 = 'next_tab',
      l2 = 'scroll_up', r2 = 'scroll_down',
      l3 = 'key:home', r3 = 'key:end',
      start = binding('new_tab', false),
    },
  },
  ['community-emacs'] = {
    name = 'Community: Emacs/readline',
    author = 'Ghostty community',
    community = true,
    description = 'D-pad sends Ctrl-P/N/B/F; face buttons cover Enter, Escape, Tab and Ctrl-G.',
    mapping = {
      dpad_up = 'key:ctrl+p', dpad_down = 'key:ctrl+n',
      dpad_left = 'key:ctrl+b', dpad_right = 'key:ctrl+f',
      south = 'key:enter', east = 'key:escape', west = 'key:tab',
      north = 'key:ctrl+g',
      l1 = 'prev_tab', r1 = 'next_tab',
      l2 = 'scroll_up', r2 = 'scroll_down',
      l3 = 'paste', r3 = 'scroll_bottom',
      start = binding('new_tab', false),
    },
  },
  ['community-vim'] = {
    name = 'Community: Vim',
    author = 'Ghostty community',
    community = true,
    description = 'D-pad sends h/j/k/l; face buttons cover Enter, Escape, colon and Tab.',
    mapping = {
      dpad_up = 'text:k', dpad_down = 'text:j',
      dpad_left = 'text:h', dpad_right = 'text:l',
      south = 'key:enter', east = 'key:escape', west = 'key:tab',
      north = 'text::',
      l1 = 'prev_tab', r1 = 'next_tab',
      l2 = 'scroll_up', r2 = 'scroll_down',
      l3 = 'paste', r3 = 'scroll_bottom',
      start = binding('new_tab', false),
    },
  },
}

M.order = { 'terminal', 'steamdeck', 'community-emacs', 'community-vim', 'custom' }

function M.add(id, layout)
  assert(type(id) == 'string' and id ~= '', 'controller layout id must be a string')
  assert(type(layout) == 'table' and type(layout.mapping) == 'table', 'controller layout needs a mapping table')
  M.layouts[id] = layout
  for _, known in ipairs(M.order) do if known == id then return layout end end
  table.insert(M.order, #M.order, id) -- keep custom last
  return layout
end

function M.config(layout)
  return {
    enabled = false,
    layout = layout or 'terminal',
    layouts = M.layouts,
    -- Set mapping to a table to use it instead of the selected layout.
    mapping = nil,
  }
end

return M
