-- Luacheck config for a Factorio 2.0 mod.
std = "lua54"
max_line_length = false
codes = true

-- Writable globals: the persistent mod table, and `data` (we mutate data.raw
-- and register prototypes/styles during the data stage).
globals = {
  "storage",
  "data",
}

-- Factorio runtime / data-stage globals (read-only).
read_globals = {
  "defines", "game", "script", "rendering", "prototypes",
  "settings", "commands", "remote", "rcon", "mods", "helpers",
  "serpent", "log", "table_size", "localised_print", "util",
  -- Factorio extends stdlib:
  "table", "math", "string",
}

-- Don't nag about these.
ignore = {
  "212", -- unused argument (event handlers often ignore their arg)
  "213", -- unused loop variable
}
