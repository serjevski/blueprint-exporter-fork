"use strict";
/*
 * Runs a Lua suite under fengari with the mod root on package.path, so
 * require("scripts.json") resolves to scripts/json.lua.
 * Usage: node .dev-test/run.js [suite.lua]   (default: .dev-test/test.lua)
 */
const path = require("path");
const { lua, lauxlib, lualib, to_luastring } = require("fengari");

const root = path.resolve(__dirname, "..");
const target = path.resolve(root, process.argv[2] || path.join(".dev-test", "test.lua"));

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

lua.lua_getglobal(L, to_luastring("package"));
lua.lua_pushstring(
  L,
  to_luastring([path.join(root, "?.lua"), path.join(root, "?", "init.lua")].join(";"))
);
lua.lua_setfield(L, -2, to_luastring("path"));
lua.lua_pop(L, 1);

if (lauxlib.luaL_loadfile(L, to_luastring(target)) !== lua.LUA_OK) {
  console.error(lua.lua_tojsstring(L, -1));
  process.exit(1);
}

if (lua.lua_pcall(L, 0, lua.LUA_MULTRET, 0) !== lua.LUA_OK) {
  console.error(lua.lua_tojsstring(L, -1));
  process.exit(1);
}
