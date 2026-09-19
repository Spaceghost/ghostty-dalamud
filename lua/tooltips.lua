-- Every tooltip the plugin shows, in one place so they can be translated.
--
-- Keys the core asks for (core/app/*.nelua) sit at the top level; the
-- settings window uses `settings` (by setting path; its default is added
-- after the sentence), `sections` (by section title) and the few named ones
-- below. Keep them short, friendly and in the same voice: say what happens,
-- not how it is built.

local M = {}

-- Seconds the pointer rests on something before its tooltip shows.
M.delay = 0.45

-- The dropdown's tab bar (core/chrome.nelua button ids).
M['tab.new'] = 'New tab'
M['tab.profiles'] = 'New tab from a profile'
M['tab.window'] = 'Pop this tab out into a window'
M['tab.pin'] = 'Pin this tab into the world where you stand'
M['tab.pet'] = 'Let this tab float beside you as a pet'
M['tab.min'] = 'Minimize this tab to the toolbar'
M['tab.cfg'] = 'Settings'
M['tab.cfg.badge'] = 'Settings (new ideas to vote on, see About)'
M['tab.share'] = 'Share your latest screenshot to the gallery'
M['tab.hide'] = 'Hide the dropdown'
M['tab.close'] = 'Close this tab'

-- A floating window's title bar.
M['window.dock'] = 'Back into the dropdown as a tab'
M['window.pet'] = 'Let it float beside you as a pet'
M['window.close'] = 'Close the terminal'

-- A world screen's title bar.
M['world.close'] = 'Close this screen'
M['world.full'] = 'Full screen (double-click the screen does it too)'
M['world.full.off'] = 'Back to its place in the world'
M['world.popin'] = 'Back into the dropdown as a tab'
M['world.pet'] = 'Let it float beside you as a pet'
M['world.pin'] = 'Pin it in the world, right where it floats'
M['world.sleep.on'] = 'Sleeps while nobody sees it; click to keep it running'
M['world.sleep.off'] = 'Keeps running while unseen; click to let it sleep'
M['world.resize'] = 'Drag to resize'

-- /help lines of the commands of their own (CONFIG.host.verb_commands).
M['command./window'] = 'Desktop windows on world panels: the picker, or pull [match|#wid] | run CMD | list | close'
M['command./ask'] = 'Ask the local AI assistant: /ask [question]'
M['command./agent'] = 'ghostty-agent: /agent ask [question] asks the local AI assistant'

-- The toolbar popup's taskbar chips.
M['chip.min'] = 'Minimized: click to bring it back'
M['chip.tab'] = 'A dropdown tab: click to show it'
M['chip.win'] = 'A window: click to bring it forward'
M['chip.pet'] = 'In the world: click to focus it'

-- The settings window.
M.theme = 'Colours for the terminals and the glass around them; your own go in themes/ in the config folder.'
M.theme_item = 'Hover to see it, click to use it.'
M.vote = 'Opens the vote page in your browser; the plugin itself sends nothing for the vote.'
M.reset = 'Forget every change made here; the defaults return on the next /term reload.'

M.sections = {
  ['Theme'] = 'Pick the colours; /term theme <name> works from chat and macros too.',
  ['Keys & controller'] = 'How the terminals open from the keyboard and the controller.',
  ['Dropdown'] = 'The Quake-style terminal that slides down from the top.',
  ['Terminals'] = 'Behaviour shared by every terminal.',
  ['Pets (terminals around your character)'] = 'Screens that float beside you and follow you around (/term pet).',
  ['Clicked world panels'] = 'What happens when you click a screen in the world.',
  ['Placing world panels (Alt + drag)'] = 'Hold Alt and drag a screen to move it.',
  ['Light'] = 'How screens react to, and cast, light.',
  ['Character animation'] = 'The pose your character holds while a terminal is out.',
  ['Bell'] = 'The ripple of light when a program rings; preview them all with /term bell demo.',
  ['Assistant (/term ask)'] = 'Ask a local AI assistant from chat: /term ask <question>. Not yet tried in game.',
  ['Flat windows in the world'] = 'Plugin windows and the chat as world panels; hold Alt over a window to pull it in. Not yet tried in game.',
  ['Gallery'] = 'Share screenshots of your terminals to the gallery on spacegho.st; /term share offers your latest.',
  ['Info bar & hidden UI'] = 'The server info bar entry, and staying visible when the game hides its UI.',
}

-- One sentence per setting (lua/settings.lua adds " Default: ...").
M.settings = {
  ['theme'] = 'Colours for the terminals and the glass around them.',
  ['toggle_mods'] = 'Keys held with ` to open and close the dropdown.',
  ['world_toggle_mods'] = 'Keys held with ` to show and hide the screens in the world.',
  ['toggle_gamepad_button'] = 'Controller button: tap toggles the dropdown, hold steps through terminals, double tap steps back.',
  ['dropdown.height'] = 'How much of the screen height the dropdown takes.',
  ['dropdown.width'] = 'How much of the screen width the dropdown takes.',
  ['dropdown.min_width'] = 'The dropdown never gets narrower than this.',
  ['dropdown.align'] = 'Where the dropdown sits across the top of the screen.',
  ['dropdown.y_offset'] = 'Room left above the dropdown, for a toolbar at the top.',
  ['dropdown.opacity'] = 'How solid the dropdown looks; lower lets the game show through.',
  ['dropdown.rounding'] = 'How round the dropdown\'s corners are.',
  ['dropdown.margin'] = 'Gap between the dropdown and the screen edges.',
  ['dropdown.font_size'] = 'Text size in the dropdown and windows.',
  ['dropdown.animation_ms'] = 'How long the slide takes; 0 appears at once.',
  ['dropdown.open_on_start'] = 'Open the dropdown as soon as the plugin loads.',
  ['dropdown.glass'] = 'A soft glass body with a highlight, instead of a flat one.',
  ['dropdown.glow'] = 'The soft light around the dropdown, brighter in the dark.',
  ['dropdown.world_tint'] = 'How much the dropdown takes on the time of day and weather.',
  ['close_on_exit'] = 'Close a terminal when its shell ends, for example after ctrl+d.',
  ['copy_on_select'] = 'Copy selected text as soon as you let go of the mouse.',
  ['cursor_blink'] = 'Let the cursor blink.',
  ['popup.font_size'] = 'Text size in the toolbar popup terminal.',
  ['world.pet.distance'] = 'How far pets float from you.',
  ['world.pet.height_above'] = 'How high pets float above your feet.',
  ['world.pet.side'] = 'How far to the side pets sit, as an angle from where you face.',
  ['world.pet.step'] = 'Space between several pets.',
  ['world.pet.stiffness'] = 'How tightly pets follow you; higher keeps up faster.',
  ['world.pet.damping'] = 'How quickly pets settle; lower lets them swing.',
  ['world.pet.bob'] = 'How much pets bob up and down.',
  ['world.pet.curve'] = 'How much pets curve around you; 0 keeps them flat.',
  ['world.pet.pixels_per_yalm'] = 'Text sharpness on pets; higher makes the text smaller and crisper.',
  ['world.pet.width'] = 'Width of a new pet in pixels.',
  ['world.pet.height'] = 'Height of a new pet in pixels.',
  ['world.pet.turn_speed'] = 'How fast pets turn to face you when selected; 0 never turns.',
  ['world.defaults.opacity'] = 'How solid screens in the world look.',
  ['world.occlusion'] = 'What hides screens: depth uses the game\'s walls and people, capsule only your character.',
  ['world.occlusion_tolerance'] = 'How far a screen may sink into a surface before it is hidden.',
  ['world.occlusion_edge'] = 'How soft the edge is where something covers a screen.',
  ['world.present.enabled'] = 'A clicked screen floats toward you.',
  ['world.present.full_screen'] = 'How much of the screen a double-clicked screen fills.',
  ['world.present.fraction'] = 'How far a clicked screen floats toward you.',
  ['world.present.distance'] = 'Where a floating screen aims to stop, in front of the camera.',
  ['world.present.min_distance'] = 'A floating screen never comes closer than this.',
  ['world.present.ease'] = 'How long the float takes.',
  ['world.present.curve_relax'] = 'How much a curved screen flattens while it floats to you.',
  ['world.walk.enabled'] = 'Your character walks up to a clicked screen.',
  ['world.walk.approach_distance'] = 'How close your character walks to a clicked screen.',
  ['world.walk.max_seconds'] = 'Your character gives up walking after this long.',
  ['world.walk.turn_speed'] = 'How fast your character turns toward a clicked screen.',
  ['world.drag.enabled'] = 'Alt + drag moves a screen; add Shift to snap to surfaces and Ctrl to stretch it.',
  ['world.drag.wheel_step'] = 'The mouse wheel pushes a dragged screen away or pulls it closer by this much.',
  ['world.drag.offset'] = 'Gap between a snapped screen and the surface.',
  ['world.drag.fit_max'] = 'The furthest a stretched screen grows each way.',
  ['world.drag.fit_margin'] = 'Space a stretched screen keeps from the surface\'s edges.',
  ['world.drag.fit_tolerance'] = 'Bumps small enough to still count as flat when stretching.',
  ['world.light.enabled'] = 'Screens react to the time of day and weather.',
  ['world.light.backlight_below'] = 'Screens light up from behind when the world gets dimmer than this.',
  ['world.light.rain_dim'] = 'How much rain darkens screens.',
  ['world.light.cast_light'] = 'Screens shine light on your character and the world around them.',
  ['world.light.light_intensity'] = 'How bright that light is.',
  ['world.light.light_range'] = 'How far that light reaches.',
  ['world.light.light_by_day'] = 'How much of that light stays on in daylight.',
  ['world.light.light_color_from_tint'] = 'That light takes on the time of day\'s colour.',
  ['world.light.shadows'] = 'That light throws shadows; costs frame time.',
  ['world.shadows.enabled'] = 'Screens cast shadows and block sunlight; experimental, and a game patch can crash it.',
  ['animation.enabled'] = 'Your character holds a pose while a terminal is out.',
  ['animation.preset'] = 'Which pose your character holds.',
  ['animation.custom_timeline'] = 'Any animation id instead of the pose; 0 uses the pose.',
  ['animation.typing_speed'] = 'How much faster the pose moves while you type.',
  ['animation.energy_decay'] = 'How quickly that typing energy fades.',
  ['animation.lock_movement'] = 'Keep your character still while holding the pose; not recommended.',
  ['bell.enabled'] = 'Show light when a program rings the terminal bell.',
  ['bell.preset'] = 'The bell\'s look; try them all with /term bell demo, custom uses the values below.',
  ['bell.from_character'] = 'Rings of light spread from your character\'s feet.',
  ['bell.ring_count'] = 'How many rings each bell sends out.',
  ['bell.max_radius'] = 'How far the rings spread.',
  ['bell.duration'] = 'How long a ring takes to spread and fade.',
  ['bell.glow_duration'] = 'How long the terminal that rang keeps glowing.',
  ['bell.follow_tint'] = 'World screens colour the bell with the light they stand in.',
  ['bell.accent.r'] = 'Red in the custom bell colour; the theme sets it until you change it.',
  ['bell.accent.g'] = 'Green in the custom bell colour; the theme sets it until you change it.',
  ['bell.accent.b'] = 'Blue in the custom bell colour; the theme sets it until you change it.',
  ['assistant.enabled'] = '/term ask opens the assistant.',
  ['adopt.auto.mappy'] = 'Mappy\'s map window becomes a pet as soon as it opens; "back to UI" puts it back until it is next opened. Off: pull it in by hand (Alt over the window, or /window adopt mappy).',
  ['assistant.view'] = 'Where the assistant opens: beside you, as a tab, or as a window.',
  ['assistant.transport'] = 'Where the assistant runs; default follows your first profile.',
  ['assistant.chat'] = 'What /term ask runs on its own; change it in lua/assistant.lua.',
  ['assistant.ask'] = 'What /term ask <question> runs, with the question added; change it in lua/assistant.lua.',
  ['gallery.prompt'] = 'After you take a screenshot with a terminal on screen, a small prompt asks whether to share it. Nothing is uploaded until you click Share.',
  ['gallery.credit'] = 'Shared screenshots carry your character\'s name and world; off, they are anonymous.',
  ['host.dtr.mode'] = 'When the server info bar entry shows; auto hides it while the Umbra widget is there.',
  ['popup.close_on_blur'] = 'The info bar popup closes when you click elsewhere.',
  ['host.keep_visible.user_hidden'] = 'Terminals stay when you hide the game UI.',
  ['host.keep_visible.cutscene'] = 'Terminals stay during cutscenes.',
  ['host.keep_visible.gpose'] = 'Terminals stay in group pose.',
}

return M
