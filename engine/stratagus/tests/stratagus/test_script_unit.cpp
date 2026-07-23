//       _________ __                 __
//      /   _____//  |_____________ _/  |______     ____  __ __  ______
//      \_____  \\   __\_  __ \__  \\   __\__  \   / ___\|  |  \/  ___/
//      /        \|  |  |  | \// __ \|  |  / __ \_/ /_/  >  |  /\___ |
//     /_______  /|__|  |__|  (____  /__| (____  /\___  /|____//____  >
//             \/                  \/          \//_____/            \/
//  ______________________                           ______________________
//                        T H E   W A R   B E G I N S
//         Stratagus - A free fantasy real time strategy game engine
//
/**@name test_script_unit.cpp - Regression tests for script_unit Lua bindings. */
//
//      (c) Copyright 2026 by The Stratagus Project
//
//      This program is free software; you can redistribute it and/or modify
//      it under the terms of the GNU General Public License as published by
//      the Free Software Foundation; only version 2 of the License.
//
//      This program is distributed in the hope that it will be useful,
//      but WITHOUT ANY WARRANTY; without even the implied warranty of
//      MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//      GNU General Public License for more details.
//
//      You should have received a copy of the GNU General Public License
//      along with this program; if not, write to the Free Software
//      Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
//      02111-1307, USA.
//

#include <doctest.h>

#include "stratagus.h"
#include "interface.h"
#include "results.h"
#include "script.h"
#include "unit.h"
#include "unit_manager.h"

// Exposed for testing — defined in script_unit.cpp
extern void UnitCclRegister();

namespace
{

// RAII fixture: initialises a minimal Lua + UnitManager environment,
// registers GetUnitVariable, and tears everything down afterwards.
struct ScriptUnitFixture
{
	CUnitManager mgr;

	ScriptUnitFixture()
	{
		GameRunning = true;
		GamePaused = false;
		GameResult = GameNoResult;
		InitLua();
		REQUIRE(Lua);
		UnitCclRegister();
		UnitManager = &mgr;
		mgr.Init();
	}

	~ScriptUnitFixture()
	{
		UnitManager = nullptr;
		if (Lua) {
			lua_close(Lua);
			Lua = nullptr;
		}
		GameRunning = false;
		GamePaused = false;
		GameResult = GameNoResult;
	}
};

// Run a Lua snippet and return whether it succeeded (no error).
bool runLua(const std::string &code)
{
	const int status = luaL_loadbuffer(Lua, code.data(), code.size(), "test");
	if (status != 0) {
		lua_pop(Lua, 1);
		return false;
	}
	return LuaCall(Lua, 0, 0, lua_gettop(Lua), /*exitOnError=*/false) == 0;
}

} // namespace

// ---------------------------------------------------------------------------
// Regression: GetUnitVariable on a destroyed unit must return nil, not crash.
//
// Root cause: CUnit::Release() calls Orders.clear() after Destroyed = 1.
// A Lua trigger holding a stale slot number called GetUnitVariable on it,
// which reached UpdateUnitVariables() → unit.CurrentOrder() on an empty
// Orders vector → out-of-bounds read → SIGSEGV.
//
// Fix: CclGetUnitVariable() guards on unit->Destroyed before calling
// UpdateUnitVariables() and returns nil for destroyed/released units.
// ---------------------------------------------------------------------------
TEST_CASE("GetUnitVariable returns nil for a destroyed unit (no crash)")
{
	ScriptUnitFixture fix;

	// Allocate slot 0.
	CUnit *unit = fix.mgr.AllocUnit();
	REQUIRE(unit != nullptr);
	const int slot = unit->UnitManagerData.GetUnitId();
	CHECK(slot == 0);

	// Simulate the state produced by CUnit::Release() after the last
	// reference drops: Destroyed = 1 and Orders cleared.
	// This is the exact state that caused the SIGSEGV.
	unit->Destroyed = 1;
	unit->Orders.clear();

	// Call GetUnitVariable(slot, "HitPoints") from Lua and capture the type
	// of the returned value.  Must not crash.
	const std::string code =
		"_result_type = type(GetUnitVariable(" + std::to_string(slot) + ", 'HitPoints'))\n";
	REQUIRE(runLua(code));

	lua_getglobal(Lua, "_result_type");
	const std::string_view t = LuaToString(Lua, -1);
	lua_pop(Lua, 1);
	CHECK(t == "nil");
}

// ---------------------------------------------------------------------------
// Sanity: GetUnitVariable with the sentinel (-1) and nothing selected still
// returns nil (existing behaviour preserved).
// ---------------------------------------------------------------------------
TEST_CASE("GetUnitVariable returns nil for sentinel -1 with nothing selected")
{
	ScriptUnitFixture fix;

	REQUIRE(runLua("_result_type = type(GetUnitVariable(-1, 'HitPoints'))\n"));

	lua_getglobal(Lua, "_result_type");
	const std::string_view t = LuaToString(Lua, -1);
	lua_pop(Lua, 1);
	CHECK(t == "nil");
}

