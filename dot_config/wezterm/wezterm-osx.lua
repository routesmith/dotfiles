-- Pull in the wezterm API
local wezterm = require("wezterm")

-- This will hold the configuration.
local config = wezterm.config_builder()

-- config.enable_csi_u_key_encoding = false
-- config.enable_kitty_keyboard = false
-- config.term = "xterm-256color"
config.audible_bell = "Disabled"

-- Rendering
config.max_fps = 120

config.window_decorations = "RESIZE"
config.window_background_opacity = 0.8
config.macos_window_background_blur = 10

-- Cursor
config.animation_fps = 120
config.default_cursor_style = "BlinkingBlock"
config.cursor_blink_rate = 650

-- Tab bar
config.enable_tab_bar = true
config.hide_tab_bar_if_only_one_tab = false
config.tab_bar_at_bottom = false
config.use_fancy_tab_bar = false
config.tab_and_split_indices_are_zero_based = true

-- Color & font
config.color_scheme = "GruvboxDarkHard"
-- config.font = wezterm.font("FiraCode Nerd Font", { weight = "Bold", italic = false })
-- config.font = wezterm.font("FiraMono Nerd Font", { weight = "Bold", italic = false })
config.font = wezterm.font("JetBrainsMono NF", { weight = "Bold", italic = false })
-- config.font = wezterm.font("Hack Nerd Font", { weight = "Bold", italic = false })
config.font_size = 13

-- and finally, return the configuration to wezterm
return config
