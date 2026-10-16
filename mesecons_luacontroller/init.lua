--        ______
--       |
--       |
--       |        __       ___  _   __         _  _
-- |   | |       |  | |\ |  |  |_| |  | |  |  |_ |_|
-- |___| |______ |__| | \|  |  | \ |__| |_ |_ |_ |\
-- |
-- |
--

-- Reference
-- ports = get_real_port_states(pos): gets if inputs are powered from outside
-- newport = merge_port_states(state1, state2): just does result = state1 or state2 for every port
-- set_port(pos, rule, state): activates/deactivates the mesecons according to the port states
-- set_port_states(pos, ports, ignore_overheat): Applies new port states to a Luacontroller at pos
-- run_inner(pos, code, event): runs code on the controller at pos and event
-- update_code(meta, code): installs new code, without resetting LCID
-- update_errmsg(meta, errmsg): installs new code, without resetting LCID
-- update_formspec(pos, refresh, code_override): displays updated formspec to players who have the UI open
-- reset_meta(pos, code, errmsg): performs a software-reset, installs new code and prints error message
-- run(pos, event): a wrapper for run_inner which gets code & handles errors via reset_meta
-- reset(pos): performs a hardware reset, turns off all ports
--
-- The Sandbox
-- The whole code of the controller runs in a sandbox,
-- a very restricted environment.
-- Actually the only way to damage the server is to
-- use too much memory from the sandbox.
-- You can add more functions to the environment
-- (see where local env is defined)
-- Something nice to play is is appending minetest.env to it.

local S = minetest.get_translator(minetest.get_current_modname())

local BASENAME = "mesecons_luacontroller:luacontroller"

local rules = {
	a = {x = -1, y = 0, z =  0, name="A"},
	b = {x =  0, y = 0, z =  1, name="B"},
	c = {x =  1, y = 0, z =  0, name="C"},
	d = {x =  0, y = 0, z = -1, name="D"},
}

-- Mod storage and library caches
local storage = minetest.get_mod_storage()
mesecon.library_storage = storage
mesecon.library_cache = mesecon.library_cache or {}
mesecon.library_call_count = mesecon.library_call_count or {}
-- Track which players have luacontroller UI currently open, with two-way lookup
mesecon.opened_luacontrollers = mesecon.opened_luacontrollers or {}
mesecon.opened_luacontrollers_players = mesecon.opened_luacontrollers_players or {}
mesecon.luacontroller_formspec_cache = mesecon.luacontroller_formspec_cache or {}
mesecon.luacontroller_formspec_cache_size = mesecon.luacontroller_formspec_cache_size or 0

local LIB_FORMAT_VERSION = storage:get_string("lib_format_version") or "legacy"

if LIB_FORMAT_VERSION == "legacy" then
	minetest.log("action", "[mesecons_luacontroller] Migrating library positions to vector.to_string format...")

	local migrated = 0
	local fields = storage:to_table().fields
	for key, _ in pairs(fields) do
		if key ~= "lib_format_version" and key:match(":") then
			local old_val = storage:get_string(key)
			if old_val and old_val ~= "" and old_val:sub(1, 1) == "{" then
				local pos = minetest.deserialize(old_val)
				if pos and pos.x then
					storage:set_string(key, vector.to_string(pos))
					migrated = migrated + 1
				end
			end
		end
	end

	storage:set_string("lib_format_version", "v1")
	minetest.log("action", "[mesecons_luacontroller] Migrated " .. migrated .. " library positions")
end
local DEFAULT_MAX_LIBRARY_CALLS = 7
local function get_max_library_calls()
	return tonumber(minetest.settings:get("mesecon_max_library_calls")) or DEFAULT_MAX_LIBRARY_CALLS
end
mesecon.get_max_library_calls = get_max_library_calls

-- Helper: strip comments/strings and count load_library calls (static check)
local function strip_comments_and_strings(code)
	if not code then return "" end
	-- remove long bracket comments/strings first
	code = code:gsub("%-%-%[%[.-%]%]", "")   -- --[[ ... ]] comments
	code = code:gsub("%[%[.-%]%]", "")       -- [[ ... ]] long strings
	-- remove single-line comments
	code = code:gsub("%-%-.-\n", "\n")
	-- remove quoted strings
	code = code:gsub("%b''", ""):gsub('%b""', "")
	return code
end

local function count_load_library_calls(code)
	local clean = strip_comments_and_strings(code)
	local count = 0
	for _ in clean:gmatch("%f[%w]load_library%s*%(") do
		count = count + 1
	end
	return count
end
mesecon.count_load_library_calls = count_load_library_calls

-- Factory: returns a load_library function bound to pos and env.
-- Used by both mesecons_luacontroller and pipeworks lua_tube.
function mesecon.make_load_library(pos, env)
	return function(libname)
		if type(libname) ~= "string" then return nil end

		local pkey = minetest.hash_node_position(pos)
		mesecon.library_call_count[pkey] = (mesecon.library_call_count[pkey] or 0) + 1
		local max_calls = mesecon.get_max_library_calls()
		if mesecon.library_call_count[pkey] > max_calls then
			error("Too many load_library() runtime calls")
		end

		local func = mesecon.library_cache[libname]

		if not func then
			local pos_str = mesecon.library_storage:get_string(libname)
			if not pos_str or pos_str == "" then return nil end
			local libpos = vector.from_string(pos_str)
			if not libpos then return nil end
			local lmeta = minetest.get_meta(libpos)
			if not lmeta then return nil end
			local code = lmeta:get_string("code")
			if not code or code == "" then return nil end

			local msg
			func, msg = loadstring(code)
			if not func then return nil end

			mesecon.library_cache[libname] = func
		end

		setfenv(func, env)
		local ok, ret = pcall(func)
		if not ok then error(ret, 0) end
		return ret
	end
end

local function remove_library_mapping(pos, meta)
	meta = meta or minetest.get_meta(pos)
	local fullname = meta:get_string("library_fullname")
	if fullname and fullname ~= "" then
		storage:set_string(fullname, "")
		mesecon.library_cache[fullname] = nil
		meta:set_string("library_fullname", "")
		meta:set_string("library_name", "")
		meta:set_int("is_library", 0)
	end
end


------------------
-- Action stuff --
------------------
-- These helpers are required to set the port states of the luacontroller

-- Updates the real port states according to the signal change.
-- Returns whether the real port states actually changed.
local function update_real_port_states(pos, rule_name, new_state)
	local meta = minetest.get_meta(pos)
	if rule_name == nil then
		meta:set_int("real_portstates", 1)
		return true
	end
	local real_portstates = meta:get_int("real_portstates")
	local n = real_portstates - 1
	local L = {}
	for i = 1, 4 do
		L[i] = n % 2
		n = math.floor(n / 2)
	end
	--                   (0,-1) (-1,0)      (1,0) (0,1)
	local pos_to_side = {  4,     1,   nil,   3,    2 }
	if rule_name.x == nil then
		for _, rname in ipairs(rule_name) do
			local port = pos_to_side[rname.x + (2 * rname.z) + 3]
			L[port] = (new_state == "on") and 1 or 0
		end
	else
		local port = pos_to_side[rule_name.x + (2 * rule_name.z) + 3]
		L[port] = (new_state == "on") and 1 or 0
	end
	local new_portstates = 1 + 1 * L[1] + 2 * L[2] + 4 * L[3] + 8 * L[4]
	if new_portstates ~= real_portstates then
		meta:set_int("real_portstates", new_portstates)
		return true
	end
	return false
end

--------------------------------------------------
-- Signal Rate Limiting
--------------------------------------------------

local SIGNAL_RATE_LIMIT = mesecon.setting("signal_rate_limit_cooldown", 0.5)

local function should_process_signal(pos, new_state)
	if new_state ~= "on" and new_state ~= "off" then
		return true
	end

	local meta = minetest.get_meta(pos)
	local now = os.time()
	local last_time = meta:get_int("signal_rate_limit") or 0

	if now - last_time < SIGNAL_RATE_LIMIT then
		return false
	end

	meta:set_int("signal_rate_limit", now)
	return true
end


local port_names = {"a", "b", "c", "d"}

local function get_real_port_states(pos)
	-- Determine if ports are powered (by itself or from outside)
	local meta = minetest.get_meta(pos)
	local L = {}
	local n = meta:get_int("real_portstates") - 1
	for _, name in ipairs(port_names) do
		L[name] = ((n % 2) == 1)
		n = math.floor(n / 2)
	end
	return L
end


local function merge_port_states(ports, vports)
	return {
		a = ports.a or vports.a,
		b = ports.b or vports.b,
		c = ports.c or vports.c,
		d = ports.d or vports.d,
	}
end

local function generate_name(ports)
	local d = ports.d and 1 or 0
	local c = ports.c and 1 or 0
	local b = ports.b and 1 or 0
	local a = ports.a and 1 or 0
	return BASENAME..d..c..b..a
end


local function set_port(pos, rule, state)
	if state then
		mesecon.receptor_on(pos, {rule})
	else
		mesecon.receptor_off(pos, {rule})
	end
end


local function clean_port_states(ports)
	ports.a = ports.a and true or false
	ports.b = ports.b and true or false
	ports.c = ports.c and true or false
	ports.d = ports.d and true or false
end

local is_controller_burnt

local function set_port_states(pos, ports, ignore_overheat)
	local node = minetest.get_node(pos)
	local name = node.name
	if not ignore_overheat and is_controller_burnt(name) then
		return -- Avoid swapping back to a non-burnt node
	end

	clean_port_states(ports)
	local vports = minetest.registered_nodes[name].virtual_portstates
	local new_name = generate_name(ports)

	if name ~= new_name and vports then
		-- Problem:
		-- We need to place the new node first so that when turning
		-- off some port, it won't stay on because the rules indicate
		-- there is an onstate output port there.
		-- When turning the output off then, it will however cause feedback
		-- so that the luacontroller will receive an "off" event by turning
		-- its output off.
		-- Solution / Workaround:
		-- Remember which output was turned off and ignore next "off" event.
		local meta = minetest.get_meta(pos)
		local ign = minetest.deserialize(meta:get_string("ignore_offevents"), true) or {}
		if ports.a and not vports.a and not mesecon.is_powered(pos, rules.a) then ign.A = true end
		if ports.b and not vports.b and not mesecon.is_powered(pos, rules.b) then ign.B = true end
		if ports.c and not vports.c and not mesecon.is_powered(pos, rules.c) then ign.C = true end
		if ports.d and not vports.d and not mesecon.is_powered(pos, rules.d) then ign.D = true end
		meta:set_string("ignore_offevents", minetest.serialize(ign))

		minetest.swap_node(pos, {name = new_name, param2 = node.param2})

		if ports.a ~= vports.a then set_port(pos, rules.a, ports.a) end
		if ports.b ~= vports.b then set_port(pos, rules.b, ports.b) end
		if ports.c ~= vports.c then set_port(pos, rules.c, ports.c) end
		if ports.d ~= vports.d then set_port(pos, rules.d, ports.d) end
	end
end


-----------------
-- Overheating --
-----------------

is_controller_burnt = function(node_name)
	return node_name == (BASENAME .. "_burnt")
end

local function burn_controller(pos)
	local node = minetest.get_node(pos)
	node.name = BASENAME.."_burnt"
	minetest.swap_node(pos, node)
	minetest.get_meta(pos):set_string("lc_memory", "");
	-- Wait for pending operations
	minetest.after(0.2, mesecon.receptor_off, pos, mesecon.rules.flat)
end

local function overheat(pos)
	if is_controller_burnt(core.get_node(pos).name) then
		-- Avoid spamming "Node overheats" log messages.
		return true
	end
	if mesecon.do_overheat(pos) then -- If too hot
		burn_controller(pos)
		return true
	end
end

------------------------
-- Ignored off events --
------------------------

local function ignore_event(event, meta)
	if event.type ~= "off" then return false end
	local ignore_offevents = minetest.deserialize(meta:get_string("ignore_offevents"), true) or {}
	if ignore_offevents[event.pin.name] then
		ignore_offevents[event.pin.name] = nil
		meta:set_string("ignore_offevents", minetest.serialize(ignore_offevents))
		return true
	end
end

-------------------------
-- Parsing and running --
-------------------------

local function safe_print(param)
	if mesecon.setting("luacontroller_print_behavior", "log") == "log" then
		local string_meta = getmetatable("")
		local sandbox = string_meta.__index
		string_meta.__index = string -- Leave string sandbox temporarily
		minetest.log("action", string.format("[mesecons_luacontroller] print(%s)", dump(param)))
		string_meta.__index = sandbox -- Restore string sandbox
	end
end

local function safe_date()
	return(os.date("*t",os.time()))
end

-- string.rep(str, n) with a high value for n can be used to DoS
-- the server. Therefore, limit max. length of generated string.
local function safe_string_rep(str, n)
	if #str * n > mesecon.setting("luacontroller_string_rep_max", 64000) then
		debug.sethook() -- Clear hook
		error("string.rep: string length overflow", 2)
	end

	return string.rep(str, n)
end

-- string.find with a pattern can be used to DoS the server.
-- Therefore, limit string.find to patternless matching.
local function safe_string_find(...)
	if (select(4, ...)) ~= true then
		debug.sethook() -- Clear hook
		error("string.find: 'plain' (fourth parameter) must always be true in a Luacontroller")
	end

	return string.find(...)
end

-- do not allow pattern matching in string.split (see string.find for details)
local function safe_string_split(...)
	if select(5, ...) then
		debug.sethook() -- Clear hook
		error("string.split: 'sep_is_pattern' (fifth parameter) may not be used in a Luacontroller")
	end

	return string.split(...)
end

local function remove_functions(x)
	local tp = type(x)
	if tp == "function" then
		return nil
	end

	-- Make sure to not serialize the same table multiple times, otherwise
	-- writing mem.test = mem in the Luacontroller will lead to infinite recursion
	local seen = {}

	local function rfuncs(x)
		if x == nil then return end
		if seen[x] then return end
		seen[x] = true
		if type(x) ~= "table" then return end

		for key, value in pairs(x) do
			if type(key) == "function" or type(value) == "function" then
				x[key] = nil
			else
				if type(key) == "table" then
					rfuncs(key)
				end
				if type(value) == "table" then
					rfuncs(value)
				end
			end
		end
	end

	rfuncs(x)

	return x
end

local function validate_iid(iid)
	if not iid then return true end -- nil is OK

	local limit = mesecon.setting("luacontroller_interruptid_maxlen", 256)
	if type(iid) == "string" then
		if #iid <= limit then return true end -- string is OK unless too long
		return false, "An interrupt ID was too large!"
	end
	if type(iid) == "number" or type(iid) == "boolean" then return true, "Non-string interrupt IDs are deprecated" end

	local warn
	local seen = {}
	local function check(t)
		if type(t) == "function" then
			warn = "Functions cannot be used in interrupt IDs"
			return false
		end
		if type(t) ~= "table" then
			return true
		end
		if seen[t] then
			warn = "Non-tree-like tables are forbidden as interrupt IDs"
			return false
		end
		seen[t] = true
		for k, v in pairs(t) do
			if not check(k) then return false end
			if not check(v) then return false end
		end
		return true
	end
	if not check(iid) then return false, warn end

	if #minetest.serialize(iid) > limit then
		return false, "An interrupt ID was too large!"
	end

	return true, "Table interrupt IDs are deprecated and are unreliable; use strings instead"
end

-- The setting affects API so is not intended to be changeable at runtime
local get_interrupt
if mesecon.setting("luacontroller_lightweight_interrupts", false) then
	-- use node timer
	get_interrupt = function(pos, itbl, send_warning)
		return (function(time, iid)
			if type(time) ~= "number" then error("Delay must be a number") end
			if iid ~= nil then send_warning("Interrupt IDs are disabled on this server") end
            --minetest.log(tonumber(time))
			if tonumber(time) < 1 then error("Delay cannot be faster than 1 second") end
			table.insert(itbl, function() minetest.get_node_timer(pos):start(time) end)
		end)
	end
else
	-- use global action queue
	-- itbl: Flat table of functions to run after sandbox cleanup, used to prevent various security hazards
	get_interrupt = function(pos, itbl, send_warning)
		-- iid = interrupt id
		return function (time, iid)
			-- NOTE: This runs within string metatable sandbox, so don't *rely* on anything of the form (""):y
			-- Hence the values get moved out. Should take less time than original, so totally compatible
			if type(time) ~= "number" then error("Delay must be a number") end
			if tonumber(time) < 1 then error("Delay cannot be faster than 1 second") end
            --minetest.log(tonumber(time))
			table.insert(itbl, function ()
				-- Outside string metatable sandbox, can safely run this now
				local luac_id = minetest.get_meta(pos):get_int("luac_id")
				local ok, warn = validate_iid(iid)
				if ok then mesecon.queue:add_action(pos, "lc_interrupt", {luac_id, iid}, time, iid, 1) end
				if warn then send_warning(warn) end
			end)
		end
	end
end

-- Given a message object passed to digiline_send, clean it up into a form
-- which is safe to transmit over the network and compute its "cost" (a very
-- rough estimate of its memory usage).
--
-- The cleaning comprises the following:
-- 1. Functions (and userdata, though user scripts ought not to get hold of
--    those in the first place) are removed, because they break the model of
--    Digilines as a network that carries basic data, and they could exfiltrate
--    references to mutable objects from one Luacontroller to another, allowing
--    inappropriate high-bandwidth, no-wires communication.
-- 2. Tables are duplicated because, being mutable, they could otherwise be
--    modified after the send is complete in order to change what data arrives
--    at the recipient, perhaps in violation of the previous cleaning rule or
--    in violation of the message size limit.
--
-- The cost indication is only approximate; it’s not a perfect measurement of
-- the number of bytes of memory used by the message object.
--
-- Parameters:
-- msg -- the message to clean
-- back_references -- for internal use only; do not provide
--
-- Returns:
-- 1. The cleaned object.
-- 2. The approximate cost of the object.
local function clean_and_weigh_digiline_message(msg, back_references)
	local t = type(msg)
	if t == "string" then
		-- Strings are immutable so can be passed by reference, and cost their
		-- length plus the size of the Lua object header (24 bytes on a 64-bit
		-- platform) plus one byte for the NUL terminator.
		return msg, #msg + 25
	elseif t == "number" then
		-- Numbers are passed by value so need not be touched, and cost 8 bytes
		-- as all numbers in Lua are doubles. NaN values are removed.
		if msg ~= msg then
			return nil, 0
		end
		return msg, 8
	elseif t == "boolean" then
		-- Booleans are passed by value so need not be touched, and cost 1
		-- byte.
		return msg, 1
	elseif t == "table" then
		-- Tables are duplicated. Check if this table has been seen before
		-- (self-referential or shared table); if so, reuse the cleaned value
		-- of the previous occurrence, maintaining table topology and avoiding
		-- infinite recursion, and charge zero bytes for this as the object has
		-- already been counted.
		back_references = back_references or {}
		local bref = back_references[msg]
		if bref then
			return bref, 0
		end
		-- Construct a new table by cleaning all the keys and values and adding
		-- up their costs, plus 8 bytes as a rough estimate of table overhead.
		local cost = 8
		local ret = {}
		back_references[msg] = ret
		for k, v in pairs(msg) do
			local k_cost, v_cost
			k, k_cost = clean_and_weigh_digiline_message(k, back_references)
			v, v_cost = clean_and_weigh_digiline_message(v, back_references)
			if k ~= nil and v ~= nil then
				-- Only include an element if its key and value are of legal
				-- types.
				ret[k] = v
			end
			-- If we only counted the cost of a table element when we actually
			-- used it, we would be vulnerable to the following attack:
			-- 1. Construct a huge table (too large to pass the cost limit).
			-- 2. Insert it somewhere in a table, with a function as a key.
			-- 3. Insert it somewhere in another table, with a number as a key.
			-- 4. The first occurrence doesn’t pay the cost because functions
			--    are stripped and therefore the element is dropped.
			-- 5. The second occurrence doesn’t pay the cost because it’s in
			--    back_references.
			-- By counting the costs regardless of whether the objects will be
			-- included, we avoid this attack; it may overestimate the cost of
			-- some messages, but only those that won’t be delivered intact
			-- anyway because they contain illegal object types.
			cost = cost + k_cost + v_cost
		end
		return ret, cost
	else
		return nil, 0
	end
end


-- itbl: Flat table of functions to run after sandbox cleanup, used to prevent various security hazards
local function get_digiline_send(pos, itbl, send_warning)
	if not minetest.global_exists("digilines") then return end
	local chan_maxlen = mesecon.setting("luacontroller_digiline_channel_maxlen", 256)
	local maxlen = mesecon.setting("luacontroller_digiline_maxlen", 50000)
	return function(channel, msg)
		-- NOTE: This runs within string metatable sandbox, so don't *rely* on anything of the form (""):y
		--        or via anything that could.
		-- Make sure channel is string, number or boolean
		if type(channel) == "string" then
			if #channel > chan_maxlen then
				send_warning("Channel string too long.")
				return false
			end
		elseif (type(channel) ~= "string" and type(channel) ~= "number" and type(channel) ~= "boolean") then
			send_warning("Channel must be string, number or boolean.")
			return false
		end

		local msg_cost
		msg, msg_cost = clean_and_weigh_digiline_message(msg)
		if msg == nil or msg_cost > maxlen then
			send_warning("Message was too complex, or contained invalid data.")
			return false
		end

		table.insert(itbl, function ()
			-- Runs outside of string metatable sandbox
			local luac_id = minetest.get_meta(pos):get_int("luac_id")
			mesecon.queue:add_action(pos, "lc_digiline_relay", {channel, luac_id, msg})
		end)
		return true
	end
end

local safe_globals = {
	-- Don't add pcall/xpcall unless willing to deal with the consequences (unless very careful, incredibly likely to allow killing server indirectly)
	"assert", "error", "ipairs", "next", "pairs", "select",
	"tonumber", "tostring", "type", "unpack", "_VERSION"
}

local function timeout()
	debug.sethook() -- Clear hook
	error("Code timed out!", 2)
end

local function create_sandbox(code, env)
	if code:byte(1) == 27 then
		return nil, "Binary code prohibited."
	end
	local f, msg = loadstring(code)
	if not f then return nil, msg end
	setfenv(f, env)

	-- Turn off JIT optimization for user code so that count
	-- events are generated when adding debug hooks
	if rawget(_G, "jit") then
		jit.off(f, true)
	end

	local maxevents = mesecon.setting("luacontroller_maxevents", 10000)
	return function(...)
		-- NOTE: This runs within string metatable sandbox, so the setting's been moved out for safety
		-- Use instruction counter to stop execution
		-- after luacontroller_maxevents
		debug.sethook(timeout, "", maxevents)
		local ok, ret = pcall(f, ...)
		debug.sethook() -- Clear hook
		if not ok then error(ret, 0) end
		return ret
	end
end

local function create_environment(pos, mem, event, itbl, send_warning)
	-- Gather variables for the environment
	local node_def = minetest.registered_nodes[minetest.get_node(pos).name]
	if not node_def then return end

	local vports = node_def.virtual_portstates
	if not vports then return end

	local vports_copy = {}
	for k, v in pairs(vports) do vports_copy[k] = v end
	local rports = get_real_port_states(pos)

	-- Create new library tables on each call to prevent one Luacontroller
	-- from breaking a library and messing up other Luacontrollers.
	local env = {
		pin = merge_port_states(vports, rports),
		port = vports_copy,
		event = event,
		mem = mem,
		heat = mesecon.get_heat(pos),
		heat_max = mesecon.setting("overheat_max", 20),
		print = safe_print,
		interrupt = get_interrupt(pos, itbl, send_warning),
		digiline_send = get_digiline_send(pos, itbl, send_warning),
		sha256sum = minetest.sha256,
		string = {
			byte = string.byte,
			char = string.char,
			format = string.format,
			len = string.len,
			lower = string.lower,
			upper = string.upper,
			rep = safe_string_rep,
			reverse = string.reverse,
			sub = string.sub,
			find = safe_string_find,
			split = safe_string_split,
		},
		math = {
			abs = math.abs,
			acos = math.acos,
			asin = math.asin,
			atan = math.atan,
			atan2 = math.atan2,
			ceil = math.ceil,
			cos = math.cos,
			cosh = math.cosh,
			deg = math.deg,
			exp = math.exp,
			floor = math.floor,
			fmod = math.fmod,
			frexp = math.frexp,
			huge = math.huge,
			ldexp = math.ldexp,
			log = math.log,
			log10 = math.log10,
			max = math.max,
			min = math.min,
			modf = math.modf,
			pi = math.pi,
			pow = math.pow,
			rad = math.rad,
			random = math.random,
			sin = math.sin,
			sinh = math.sinh,
			sqrt = math.sqrt,
			tan = math.tan,
			tanh = math.tanh,
		},
		table = {
			concat = table.concat,
			insert = table.insert,
			maxn = table.maxn,
			remove = table.remove,
			sort = table.sort,
		},
		os = {
			clock = os.clock,
			difftime = os.difftime,
			time = os.time,
			datetable = safe_date,
		},
		bit = {
			tobit = bit.tobit,
			tohex = bit.tohex,
			bnot = bit.bnot,
			bor = bit.bor,
			band = bit.band,
			bxor = bit.bxor,
			lshift = bit.lshift,
			rshift = bit.rshift,
			arshift = bit.arshift,
			rol = bit.rol,
			ror = bit.ror,
			bswap = bit.bswap,
		},
	}
	env._G = env

	for _, name in pairs(safe_globals) do
		env[name] = _G[name]
	end

	-- Export load_library into the environment
	local meta = minetest.get_meta(pos)
	local node_is_library = (meta and meta:get_int("is_library") == 1) and true or false
	if node_is_library then
		env.load_library = function()
			error("load_library is not allowed in library code")
		end
	else
		env.load_library = mesecon.make_load_library(pos, env)
	end

	return env
end


local function load_memory(meta)
	return minetest.deserialize(meta:get_string("lc_memory"), true) or {}
end

local function load_errors(meta)
	return minetest.deserialize(meta:get_string("luac_errors"), true) or {}
end

local function save_errors(meta, errs)
	meta:set_string("luac_errors", minetest.serialize(errs))
	meta:mark_as_private("luac_errors")
end

local function add_error(meta, errmsg, event_type)
	local errs = load_errors(meta)
	table.insert(errs, {time = os.time(), msg = tostring(errmsg), event_type = tostring(event_type or "")})
	-- keep only last 10
	while #errs > 10 do table.remove(errs, 1) end
	save_errors(meta, errs)
end


local function serialize_memory(mem)
	return minetest.serialize(remove_functions(mem))
end


local function save_serialized_memory(pos, meta, memstring)
	local memsize_max = mesecon.setting("luacontroller_memsize", 100000)

	if (#memstring <= memsize_max) then
		meta:set_string("lc_memory", memstring)
		meta:mark_as_private("lc_memory")
	else
		print("Error: Luacontroller memory overflow. "..memsize_max.." bytes available, "
				..#memstring.." required. Controller overheats.")
		burn_controller(pos)
	end
end

-- Returns success (boolean), errmsg (string)
-- run (as opposed to run_inner) is responsible for setting up meta according to this output
local function run_inner(pos, code, event)
	local pkey = minetest.hash_node_position(pos)
	-- initialize per-execution runtime counter
	mesecon.library_call_count[pkey] = 0

	local function _body()
		local meta = minetest.get_meta(pos)
		-- Note: These return success, presumably to avoid changing LC ID.
		if overheat(pos) then return true, "" end
		if ignore_event(event, meta) then return true, "" end

		-- Load mem from meta
		local mem  = load_memory(meta)

		-- 'Last warning' label.
		local warning = ""
		local function send_warning(str)
			warning = "Warning: " .. str
		end

		-- Create environment
		local itbl = {}
		local env = create_environment(pos, mem, event, itbl, send_warning)
		if not env then return false, "Env does not exist. Controller has been reprogrammed or moved?" end

		local success, msg
		-- Create the sandbox and execute code
		local f
		f, msg = create_sandbox(code, env)
		if not f then return false, msg end
		local mem_use_limit = collectgarbage("count") + mesecon.setting("luacontroller_volatile_mem_limit", 2000)
		local oom_msg = "not enough memory" -- Used to detect OOM errors, kind of a hack.
		-- Start string true sandboxing
		local onetruestring = getmetatable("")
		-- If a string sandbox is already up yet inconsistent, something is very wrong
		assert(onetruestring.__index == string)
		onetruestring.__index = env.string
		success, msg = pcall(f)
		onetruestring.__index = string
		-- End string true sandboxing
		if collectgarbage("count") > mem_use_limit then
			-- Volatile memory limit exceeded.
			success = false
			msg = oom_msg
		end
		-- Serialize the persistent memory.
		local memstring
		if success then
			success, memstring = pcall(serialize_memory, env.mem)
			if not success then
				msg = memstring
				-- Rethrow non-OOM errors.
				if msg ~= oom_msg then error(msg, 0) end
			end
		end
		if not success then
			-- Handle OOM errors by collecting garbage.
			if msg == oom_msg then
				env, itbl, mem = nil -- Let the memory be collected.
				collectgarbage()
				print("Error: Luacontroller at " .. minetest.pos_to_string(pos)
						.. " exhausted its available volatile memory. Controller overheats.")
				burn_controller(pos)
			end
			return false, msg
		end
		if type(env.port) ~= "table" then
			return false, "Ports set are invalid."
		end

		-- Actually set the ports
		set_port_states(pos, env.port)

		-- Save memory. This may burn the luacontroller if a memory overflow occurs.
		save_serialized_memory(pos, meta, memstring)

		-- Execute deferred tasks
		for _, v in ipairs(itbl) do
			local failure = v()
			if failure then
				return false, failure
			end
		end
		return true, warning
	end

	local ok, res1 = _body()
	-- Clear runtime counter
	mesecon.library_call_count[pkey] = nil
	return ok, res1
end

local function update_errmsg(meta, errmsg)
	errmsg = errmsg or ""
	meta:set_string("luac_errmsg", errmsg)
	meta:mark_as_private("luac_errmsg")
end

local function update_code(meta, code)
	code = code or ""
	local err = nil
	-- Limit code length to values set by mesecon.luacontroller_code_maxlen
	-- and mesecon.luacontroller_library_maxlen settings in minetest.conf or defaults
	local limit
	if meta:get_int("is_library") == 1 then
		limit = mesecon.setting("luacontroller_library_maxlen", 524288) -- 512 KiB
	else
		limit = mesecon.setting("luacontroller_code_maxlen", 35000)
	end
	if #code > limit then
		code = code:sub(1, limit)
		minetest.log("warning", "Luacontroller at "..dump(pos).." truncated to "..tostring(limit).." characters.")
		err =  "Code truncated to "..tostring(limit).." characters. Please shorten your script."
	end
	meta:set_string("code", code)
	meta:mark_as_private("code")
	return err
end

local function formspec_opened_unchecked(name, pos_str)
	mesecon.opened_luacontrollers_players[name] = pos_str
	if mesecon.opened_luacontrollers[pos_str] == nil then
		mesecon.opened_luacontrollers[pos_str] = {}
	end
	mesecon.opened_luacontrollers[pos_str][name] = true
end

local function formspec_closed_unchecked(name, pos_str)
	mesecon.opened_luacontrollers[pos_str][name] = nil
	if next(mesecon.opened_luacontrollers[pos_str]) == nil then
		mesecon.opened_luacontrollers[pos_str] = nil
	end
	mesecon.opened_luacontrollers_players[name] = nil
end

local function formspec_opened(name, pos)
	if (name == nil or name == "" or not pos) then return end
	local pos_str = vector.to_string(pos)
	if not pos_str then return end
	formspec_opened_unchecked(name, pos_str)
end

local function formspec_closed(name)
	if (name == nil or name == "") then return end
	local pos_str = mesecon.opened_luacontrollers_players[name]
	if not pos_str then 
		mesecon.opened_luacontrollers_players[name] = nil
		return
	end
	formspec_closed_unchecked(name, pos_str)
end

local function clear_opened_formspecs(pos)
	local pos_str = vector.to_string(pos)
	local pkey = minetest.hash_node_position(pos)
	if not pos_str then return end
	for player,_ in pairs(mesecon.opened_luacontrollers[pos_str] or {}) do
		minetest.close_formspec(player, BASENAME)
		mesecon.opened_luacontrollers_players[player] = nil
	end
	mesecon.opened_luacontrollers[pos_str] = nil
	-- Also clear the cache associated with this controller
	if mesecon.luacontroller_formspec_cache[pkey] ~= nil then
		mesecon.luacontroller_formspec_cache[pkey] = nil
		if mesecon.luacontroller_formspec_cache_size > 0 then
			mesecon.luacontroller_formspec_cache_size = mesecon.luacontroller_formspec_cache_size - 1
		end
	end
end

-- Engine limits formspecs to ~750KB, worst case scenario is < 200MB
-- In norml use will be magnitudes less even when full
-- Other failsafes also limit formspec size
local MAX_FORMSPEC_CACHE_SIZE = mesecon.setting("max_formspec_cache_size", 200)
-- Memory can actually store significantly more characters then luacontroller_memsize if the data is highly compressible
-- This can lead to client hangs and network issues when the formspec is sent to client
local MAX_MEMORY_DiSPLAY_SIZE = mesecon.setting("max_memory_display_size", 524288) -- 512 KiB

local function update_formspec(pos, refresh, code_override)
	local pos_str = vector.to_string(pos)
	local pkey = minetest.hash_node_position(pos)
	local opened = mesecon.opened_luacontrollers[pos_str]
	if opened == nil then
		 -- No players are viewing the formspec, evict the old cache instead of refreshing and exit
		if (refresh and mesecon.luacontroller_formspec_cache[pkey] ~= nil) then
			mesecon.luacontroller_formspec_cache[pkey] = nil
			if mesecon.luacontroller_formspec_cache_size > 0 then
				mesecon.luacontroller_formspec_cache_size = mesecon.luacontroller_formspec_cache_size - 1
			end
		end
		return
	end
	local meta = minetest.get_meta(pos)
	local cache = mesecon.luacontroller_formspec_cache[pkey]
	local legacy = meta:get_string("formspec")
	local formspec
	if (refresh or (cache == nil and legacy == "")) then
		local errmsg = meta:get_string("luac_errmsg")
		local tab_sel = meta:get_int("luac_tab_sel")
		if tab_sel == 0 then tab_sel = 1 end
		-- Determine whether we have errors to show
		local errs = load_errors(meta)
		local has_errors = (#errs > 0)
		-- Build tabs string
		local tabs = "Code,Memory"
		if has_errors then tabs = tabs .. ",Errors" end
		-- Clamp selection
		if not has_errors and tab_sel > 2 then tab_sel = 1 end
		formspec = "size[12,11]"
			.."style_type[label,textarea;font=mono]"
			.."background[-0.2,-0.25;12.4,11.75;jeija_luac_background.png]"
			.."tabheader[0,0;luac_tab;"..tabs..";"..tostring(tab_sel)..";false;false]"

		if tab_sel == 1 then
			local code = minetest.formspec_escape(code_override or meta:get_string("code"))
			local is_lib = meta:get_int("is_library")
			local lib_name = minetest.formspec_escape(meta:get_string("library_name"))
			local full_name = minetest.formspec_escape(meta:get_string("library_fullname"))
			if is_lib == 1 then
				formspec = formspec
					.."textarea[0.2,0.2;12.2,9.5;code;;"..code.."]"
					.."checkbox[0.2,9.75;is_library;Library;true]"
					.."field[2.0,10.0;4.5,0.8;library_name;Library name;"..lib_name.."]"
					.."image_button[8.75,9.9;1.5,0.8;jeija_luac_savebutton.png;save_library;]"
					.."textarea[0.5,10.5;11.6,0.75;;Full library name: "..full_name..";]"
			else
				formspec = formspec
					.."textarea[0.2,0.2;12.2,9.5;code;;"..code.."]"
					.."checkbox[0.2,9.75;is_library;Library;false]"
					.."image_button[8.75,9.9;2.5,0.8;jeija_luac_runbutton.png;program;]"
			end
		elseif tab_sel == 2 then
			local mem = load_memory(meta)
			local mem_text = minetest.formspec_escape(dump(mem))
			local mem_size = #mem_text
			if mem_size > MAX_MEMORY_DiSPLAY_SIZE then
				mem_text = mem_text:sub(1, MAX_MEMORY_DiSPLAY_SIZE)
				errmsg =  "Displayed memory truncated to "..tostring(limit).." characters. Total size is "..tostring(mem_size).."."
			end
			formspec = formspec
				.."textarea[0.2,0.2;12.2,9.5;;;"..mem_text.."]"
			-- Auto-refresh checkbox stored per-node in meta as luac_mem_autorefresh (1 = on, 0 = off).
			local autoref = meta:get_int("luac_mem_autorefresh")
			-- default to enabled if unset
			if autoref == 0 and meta:get_string("luac_mem_autorefresh") == "" then autoref = 1 end
			if autoref == 1 then
				formspec = formspec .. "checkbox[2.5,9.25;mem_autoref;Auto-refresh;true]"
				-- when autoref is enabled, no manual refresh button
			else
				formspec = formspec .. "checkbox[2.5,9.25;mem_autoref;Auto-refresh;false]"
				formspec = formspec .. "button[4.75,9.25;2.5,0.8;refresh;Refresh]"
			end
		elseif tab_sel == 3 and has_errors then
			-- format errors into a readable multi-line string
			local lines = {}
			for i = #errs, 1, -1 do
				local e = errs[i]
				local ts = os.date("%Y-%m-%d %H:%M:%S", e.time)
				local ev = e.event_type or ""
				table.insert(lines, "["..ts.."] ("..ev..") "..(e.msg or ""))
			end
			local err_text = minetest.formspec_escape(table.concat(lines, "\n"))
			formspec = formspec .. "textarea[0.2,0.2;12.2,9.0;;;"..err_text.."]"
			formspec = formspec .. "button[2.25,9.25;2.5,0.8;refresh_errors;Refresh]"
			formspec = formspec .. "button[4.75,9.25;2.5,0.8;clear_errors;Clear]"
		end
		formspec = formspec
			.."hypertext[0.3,8.35;13,0.6;error;"..errmsg.."]"
			.."image_button_exit[11.72,-0.25;0.425,0.4;jeija_close_window.png;exit;]"
		-- Clear the cache if it got too large before adding to it
		if mesecon.luacontroller_formspec_cache_size > MAX_FORMSPEC_CACHE_SIZE then
			mesecon.luacontroller_formspec_cache = {}
			mesecon.luacontroller_formspec_cache_size = 0
		end
		mesecon.luacontroller_formspec_cache[pkey] = formspec
		mesecon.luacontroller_formspec_cache_size = mesecon.luacontroller_formspec_cache_size + 1
		-- Delete formspec from old controllers
		if legacy ~= "" then meta:set_string("formspec", "") end
	elseif legacy ~= "" then
		-- Display old formspec still stored in meta to preserve the errmsg
		formspec = legacy
	else
		formspec = cache
	end
	for player,_ in pairs(opened) do
		if (mesecon.opened_luacontrollers_players[player] ~= nil) then
			minetest.show_formspec(player, BASENAME, formspec)
		else
			-- This should not have happened, close UI and clear inconsistent record
			minetest.close_formspec(player, BASENAME)
			formspec_closed_unchecked(player, pos_str)
		end
	end
end

local function reset_meta(pos, code, errmsg)
	local meta = minetest.get_meta(pos)
	local err = update_code(meta, code)
	update_errmsg(meta, err or errmsg)
	update_formspec(pos, true)
	meta:set_int("luac_id", math.random(1, 65535))
	return err
end

-- Initialize library-related fields for a new luacontroller
local function on_construct(pos)
	local meta = minetest.get_meta(pos)
	meta:set_int("is_library", 0)
	meta:set_string("library_fullname", "")
	meta:set_string("library_name", "")
	meta:set_int("luac_tab_sel", 1)  -- Default to Code tab
	meta:set_int("luac_mem_autorefresh", 1)  -- Auto-refresh enabled by default
	meta:set_string("luac_errmsg", "")
	reset_meta(pos, "", "")
end

-- Show formspec UI to player when they click the controller
local function on_rightclick(pos, node, clicker, itemstack, pointed_thing)
	local name = clicker and clicker:get_player_name() or ""
	if (name ~= "") then
		formspec_opened(name, pos)
		update_formspec(pos, false)
	end
	return itemstack
end

-- Wraps run_inner with LC-reset-on-error
local function run(pos, event)
	local meta = minetest.get_meta(pos)
	-- Library controllers don't process events - they're just code storage
	if meta:get_int("is_library") == 1 then
		return true, ""
	end
	local code = meta:get_string("code")
	local ok, errmsg = run_inner(pos, code, event)
	if not ok then
		-- record error in node meta (all errors)
		local meta = minetest.get_meta(pos)
		add_error(meta, errmsg, event and event.type)
		-- Only perform a full reset (which overwrites stored code and the formspec)
		-- when the run was triggered by an explicit program upload from a player.
		if event and event.type == "program" then
			reset_meta(pos, code, errmsg)
		else -- Otherwise refresh the formspec to display the error
			update_errmsg(meta, errmsg)
			update_formspec(pos, true)
		end
	else
		-- Preserve the last selected tab (stored in node meta). Default to 1 (Code).
		local sel = meta:get_int("luac_tab_sel")
		if (sel == 1 or sel == 0) then
			-- Code tab selected
			-- there is absolutely no need to refresh the formspec as nothing will visibly change
		elseif sel == 2 then
			-- If Memory tab is selected, only refresh formspec when autorefresh is enabled.
			local autoref = meta:get_int("luac_mem_autorefresh")
			if autoref == 1 then
				local mem = load_memory(meta)
				local mem_text = minetest.formspec_escape(dump(mem))
				update_errmsg(meta, errmsg)
				update_formspec(pos, true)
			else
				-- autoref disabled: do not rebuild the formspec on external events
			end
		elseif sel == 3 then
			-- If Errors tab is selected, do not rebuild the formspec on external events;
			-- errors are recorded and the Errors tab will reflect them when the user opens it or refreshes.
		else
			-- Unknown selection: do not update anything
		end
	end
	return ok, errmsg
end

local function reset(pos)
	set_port_states(pos, {a=false, b=false, c=false, d=false}, true)
end

local function node_timer(pos)
	if is_controller_burnt(core.get_node(pos).name) then
		return false
	end
	run(pos, {type="interrupt"})
	return false
end

-----------------------
-- A.Queue callbacks --
-----------------------

mesecon.queue:add_function("lc_interrupt", function (pos, luac_id, iid)
	-- There is no luacontroller anymore / it has been reprogrammed / replaced / burnt
	if (minetest.get_meta(pos):get_int("luac_id") ~= luac_id) then return end
	if is_controller_burnt(core.get_node(pos).name) then return end
	run(pos, {type="interrupt", iid = iid})
end)

mesecon.queue:add_function("lc_digiline_relay", function (pos, channel, luac_id, msg)
	if not digiline then return end
	-- This check is only really necessary because in case of server crash, old actions can be thrown into the future
	if (minetest.get_meta(pos):get_int("luac_id") ~= luac_id) then return end
	-- This escapes the sandbox, thus give a harsh penalty.
	if overheat(pos) then return end
	-- The actual work
	digiline:receptor_send(pos, digiline.rules.default, channel, msg)
end)

-----------------------
-- Node Registration --
-----------------------

local output_rules = {}
local input_rules = {}

local node_box = {
	type = "fixed",
	fixed = {
		{-8/16, -8/16, -8/16, 8/16, -7/16, 8/16}, -- Bottom slab
		{-5/16, -7/16, -5/16, 5/16, -6/16, 5/16}, -- Circuit board
		{-3/16, -6/16, -3/16, 3/16, -5/16, 3/16}, -- IC
	}
}

local selection_box = {
	type = "fixed",
	fixed = { -8/16, -8/16, -8/16, 8/16, -5/16, 8/16 },
}

local digiline = {
	receptor = {},
	effector = {
		action = function(pos, _, channel, msg)
			msg = clean_and_weigh_digiline_message(msg)
			run(pos, {type = "digiline", channel = channel, msg = msg})
		end
	}
}

local function get_program(pos)
	local meta = minetest.get_meta(pos)
	return meta:get_string("code")
end

local function set_program(pos, code)
	reset(pos)
	local err = reset_meta(pos, code)
	-- Do not run the code if reset was not sucessful
	if err ~= nil then return false, err end
	return run(pos, {type="program"})
end

local function receive_fields(player, formname, fields)
	if formname ~= BASENAME then return false end
	local name = player and player:get_player_name() or ""
	if name == "" then return true end
	local pos_str = mesecon.opened_luacontrollers_players[name]
	if not pos_str then return true end
	local pos = vector.from_string(pos_str)
	if not pos then return true end
	-- Handle player closing the formspec
	if fields.quit == true then
		formspec_closed_unchecked(name, pos_str)
	end
	-- Handle programming, tab switching and memory refresh
	if fields.program or fields.save_library then
		if minetest.is_protected(pos, name) and not minetest.check_player_privs(name, {protection_bypass=true}) then
			minetest.record_protection_violation(pos, name)
			return true
		end
		local meta = minetest.get_meta(pos)
		local code = fields.code or ""
		-- Determine mode by which button was pressed: save_library => library save, program => normal save
		local is_library = (fields.save_library ~= nil)
		local library_name = fields.library_name or meta:get_string("library_name")

		-- Static check: count load_library calls
		local calls = count_load_library_calls(code)
		local limit = is_library and 0 or get_max_library_calls()
		if calls > limit then
			update_code(meta, "")
			update_errmsg(meta, "Too many load_library() calls ("..calls.."). Limit is "..limit..".")
			update_formspec(pos, true, code)
			return true
		end

		-- If saving as library, validate name
		if is_library then
			if not library_name or library_name == "" then
				-- Clear the code from "code" metadata but not formspec so user does not lose it
				update_code(meta, "")
				update_errmsg(meta, "Library name cannot be empty!")
				update_formspec(pos, true, code)
				return true
			end
			if #library_name > 256 then
				update_code(meta, "")
				update_errmsg(meta, "Library name too long (max 256).")
				update_formspec(pos, true, code)
				return true
			end
			if not library_name:match("^[A-Za-z0-9,%.%-%_=+@#%%*]+$") then
				update_code(meta, "")
				update_errmsg(meta, "Library name contains invalid characters.")
				update_formspec(pos, true, code)
				return true
			end
		end

		if is_library then
			local curpos_str = vector.to_string(pos)
			local old_fullname = meta:get_string("library_fullname")
			local fullname = name .. ":" .. library_name

			if old_fullname ~= fullname then
				local other = storage:get_string(fullname)
				if other ~= "" and other ~= curpos_str then
					update_code(meta, "")
					update_errmsg(meta, "Duplicate library name for another controller.")
					update_formspec(pos, true, code)
					return true
				end

				if old_fullname and old_fullname ~= "" then
					storage:set_string(old_fullname, "")
					mesecon.library_cache[old_fullname] = nil
				end

				storage:set_string(fullname, curpos_str)
			end
			
			-- Save code and library metadata (no execution)
			local err = update_code(meta, code)
			meta:set_string("library_fullname", fullname)
			meta:set_string("library_name", library_name)
			meta:set_int("is_library", 1)
			meta:set_int("luac_id", math.random(1, 65535))

			-- Error occured when saving code - show it
			if err ~= nil then
				update_errmsg(meta, err)
				update_formspec(pos, true)
				return true
			end
			
			-- Check syntax without executing
			if code:byte(1) == 27 then
				update_errmsg(meta, "Binary code prohibited.")
				update_formspec(pos, true)
				return true
			end
			local f, msg = loadstring(code)
			if not f then
				-- Syntax error - show it
				update_errmsg(meta, msg or "Syntax error")
				update_formspec(pos, true)
				return true
			end
			
			-- Clear cache to force reload on next use
			mesecon.library_cache[fullname] = nil
			-- Show success message
			update_errmsg(meta, "Library saved successfully!")
			update_formspec(pos, true)
		else
			local old_fullname = meta:get_string("library_fullname")
			
			-- switching to normal controller: remove old mapping if exists
			if old_fullname and old_fullname ~= "" then
				storage:set_string(old_fullname, "")
				mesecon.library_cache[old_fullname] = nil
			end
			meta:set_string("library_fullname", "")
			meta:set_string("library_name", "")
			meta:set_int("is_library", 0)

			-- Attempt to set program (this will call reset_meta and run)
			local ok, err = set_program(pos, code)
			if not ok then
				minetest.log("action", "Lua controller programming error: " .. tostring(err))
				return true
			end
		end

		return true
	end

	if fields.luac_tab then
		local sel = tonumber(fields.luac_tab) or 1
		local meta = minetest.get_meta(pos)
		meta:set_int("luac_tab_sel", sel)
		update_errmsg(meta, "")
		update_formspec(pos, true)
		return true
	end

	-- Handle autorefresh checkbox toggle
	if fields.mem_autoref ~= nil then
		if minetest.is_protected(pos, name) and not minetest.check_player_privs(name, {protection_bypass=true}) then
			minetest.record_protection_violation(pos, name)
			return true
		end
		local meta = minetest.get_meta(pos)
		local enabled = (fields.mem_autoref == "true") and 1 or 0
		meta:set_int("luac_mem_autorefresh", enabled)
		-- Rebuild formspec to reflect new checkbox/button state
		update_formspec(pos, true)
		return true
	end

	-- Handle Library checkbox toggle (show/hide library_name field)
	if fields.is_library ~= nil then
		if minetest.is_protected(pos, name) and not minetest.check_player_privs(name, {protection_bypass=true}) then
			minetest.record_protection_violation(pos, name)
			return true
		end
		local meta = minetest.get_meta(pos)
		local enabled = (fields.is_library == "true") and 1 or 0
		meta:set_int("is_library", enabled)
		-- Rebuild formspec to show/hide library_name and change button
		update_formspec(pos, true)
		return true
	end

	if fields.refresh or fields.refresh_errors then
		if minetest.is_protected(pos, name) and not minetest.check_player_privs(name, {protection_bypass=true}) then
			minetest.record_protection_violation(pos, name)
			return true
		end
		local meta = minetest.get_meta(pos)
		update_errmsg(meta, "")
		update_formspec(pos, true)
		return true
	end

	-- Handle clearing errors list
	if fields.clear_errors then
		if minetest.is_protected(pos, name) and not minetest.check_player_privs(name, {protection_bypass=true}) then
			minetest.record_protection_violation(pos, name)
			return true
		end
		local meta = minetest.get_meta(pos)
		save_errors(meta, {})
		local sel = meta:get_int("luac_tab_sel")
		if (sel == 3 or sel == 0) then meta:set_int("luac_tab_sel", 1) end
		update_errmsg(meta, "")
		update_formspec(pos, true)
		return true
	end
	return true
end

minetest.register_on_player_receive_fields(receive_fields)

-- No longer send formspec updates to player who dies or logs off
core.register_on_dieplayer(function(ref, reason)
	local name = ref and ref:get_player_name() or ""
	formspec_closed(name)
end)

core.register_on_leaveplayer(function(ref, timed_out)
	local name = ref and ref:get_player_name() or ""
	formspec_closed(name)
end)

-- Clear currently opened coltroller for a player that just joined in case this somehow was still set
core.register_on_joinplayer(function(ref, last_login)
	local name = ref and ref:get_player_name() or ""
	formspec_closed(name)
end)

local controller_nodenames = {}

for a = 0, 1 do -- 0 = off  1 = on
for b = 0, 1 do
for c = 0, 1 do
for d = 0, 1 do
	local cid = tostring(d)..tostring(c)..tostring(b)..tostring(a)
	local node_name = BASENAME..cid
	local top = "jeija_luacontroller_top.png"
	if a == 1 then
		top = top.."^jeija_luacontroller_LED_A.png"
	end
	if b == 1 then
		top = top.."^jeija_luacontroller_LED_B.png"
	end
	if c == 1 then
		top = top.."^jeija_luacontroller_LED_C.png"
	end
	if d == 1 then
		top = top.."^jeija_luacontroller_LED_D.png"
	end

	local groups
	if a + b + c + d ~= 0 then
		groups = {dig_immediate=2, not_in_creative_inventory=1, overheat = 1}
	else
		groups = {dig_immediate=2, overheat = 1}
	end

	output_rules[cid] = {}
	input_rules[cid] = {}
	if a == 1 then table.insert(output_rules[cid], rules.a) end
	if b == 1 then table.insert(output_rules[cid], rules.b) end
	if c == 1 then table.insert(output_rules[cid], rules.c) end
	if d == 1 then table.insert(output_rules[cid], rules.d) end

	if a == 0 then table.insert( input_rules[cid], rules.a) end
	if b == 0 then table.insert( input_rules[cid], rules.b) end
	if c == 0 then table.insert( input_rules[cid], rules.c) end
	if d == 0 then table.insert( input_rules[cid], rules.d) end

	local mesecons = {
		effector = {
			rules = input_rules[cid],
			action_change = function (pos, _, rule_name, new_state)
				if not update_real_port_states(pos, rule_name, new_state) then
					return
				end
				if not should_process_signal(pos, new_state) then
					return
				end
				run(pos, {type=new_state, pin=rule_name})
			end,
		},
		receptor = {
			state = mesecon.state.on,
			rules = output_rules[cid]
		},
		luacontroller = {
			get_program = get_program,
			set_program = set_program,
		},
	}

	table.insert(controller_nodenames, node_name)
	minetest.register_node(node_name, {
		description = S("Luacontroller"),
		drawtype = "nodebox",
		tiles = {
			top,
			"jeija_microcontroller_bottom.png",
			"jeija_microcontroller_sides.png",
			"jeija_microcontroller_sides.png",
			"jeija_microcontroller_sides.png",
			"jeija_microcontroller_sides.png"
		},
		inventory_image = top,
		paramtype = "light",
		is_ground_content = false,
		groups = groups,
		drop = BASENAME.."0000",
		sunlight_propagates = true,
		selection_box = selection_box,
		node_box = node_box,
		on_construct = on_construct,
		on_rightclick = on_rightclick,
		sounds = mesecon.node_sound.stone,
		mesecons = mesecons,
		digiline = digiline,
		-- Virtual portstates are the ports that
		-- the node shows as powered up (light up).
		virtual_portstates = {
			a = a == 1,
			b = b == 1,
			c = c == 1,
			d = d == 1,
		},
		on_destruct = function(pos)
			-- Called BEFORE node/meta removal - library mapping still accessible
			clear_opened_formspecs(pos)
			remove_library_mapping(pos)
		end,
		after_dig_node = function (pos)
			mesecon.do_cooldown(pos)
			mesecon.receptor_off(pos, output_rules)
		end,
		is_luacontroller = true,
		on_timer = node_timer,
		on_blast = mesecon.on_blastnode,
	})
end
end
end
end

------------------------------
-- Overheated Luacontroller --
------------------------------

minetest.register_node(BASENAME .. "_burnt", {
	drawtype = "nodebox",
	tiles = {
		"jeija_luacontroller_burnt_top.png",
		"jeija_microcontroller_bottom.png",
		"jeija_microcontroller_sides.png",
		"jeija_microcontroller_sides.png",
		"jeija_microcontroller_sides.png",
		"jeija_microcontroller_sides.png"
	},
	inventory_image = "jeija_luacontroller_burnt_top.png",
	paramtype = "light",
	is_ground_content = false,
	groups = {dig_immediate=2, not_in_creative_inventory=1},
	drop = BASENAME.."0000",
	sunlight_propagates = true,
	selection_box = selection_box,
	node_box = node_box,
	on_construct = on_construct,
	on_rightclick = on_rightclick,
	sounds = mesecon.node_sound.stone,
	virtual_portstates = {a = false, b = false, c = false, d = false},
	mesecons = {
		effector = {
			rules = mesecon.rules.flat,
			action_change = function(pos, _, rule_name, new_state)
				update_real_port_states(pos, rule_name, new_state)
			end,
		},
	},
	on_blast = mesecon.on_blastnode,
	on_destruct = function(pos)
		-- Called BEFORE node/meta removal - library mapping still accessible
		clear_opened_formspecs(pos)
		remove_library_mapping(pos)
	end,
	after_dig_node = function(pos)
		-- No additional cleanup needed, on_destruct handles library removal
	end,
})

------------------------
-- Craft Registration --
------------------------

minetest.register_craft({
	output = BASENAME.."0000 2",
	recipe = {
		{'mesecons_materials:silicon', 'mesecons_materials:silicon', 'group:mesecon_conductor_craftable'},
		{'mesecons_materials:silicon', 'mesecons_materials:silicon', 'group:mesecon_conductor_craftable'},
		{'group:mesecon_conductor_craftable', 'group:mesecon_conductor_craftable', ''},
	}
})
