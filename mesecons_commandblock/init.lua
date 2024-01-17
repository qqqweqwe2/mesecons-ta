local S = minetest.get_translator(minetest.get_current_modname())
local param_maxlen = mesecon.setting("commandblock_param_maxlen", 10000)

local mod_storage = minetest.get_mod_storage()

minetest.register_chatcommand("say", {
	params = "<text>",
	description = S("Say <text> as the server"),
	privs = {server=true},
	func = function(name, param)
		minetest.chat_send_all(name .. ": " .. param)
	end
})

minetest.register_chatcommand("tell", {
	params = "<name> <text>",
--	description = S("Say <text> to <name> privately"),
	description = "Deprecated. Use /msg instead",
	privs = {shout=true},
	func = function(name, param)
--[[
		local found, _, target, message = param:find("^([^%s]+)%s+(.*)$")
		if found == nil then
			minetest.chat_send_player(name, "Invalid usage: " .. param)
			return
		end
		if not minetest.get_player_by_name(target) then
			minetest.chat_send_player(name, "Invalid target: " .. target)
		end
		minetest.chat_send_player(target, name .. " whispers: " .. message, false)
]]
		minetest.chat_send_player(name, "Command /tell is deprecated. Use /msg instead.")
	end
})

minetest.register_chatcommand("hp", {
	params = "<name> <value>",
	description = S("Set health of <name> to <value> hitpoints"),
	privs = {ban=true},
	func = function(name, param)
		local found, _, target, value = param:find("^([^%s]+)%s+(%d+)$")
		if found == nil then
			minetest.chat_send_player(name, "Invalid usage: " .. param)
			return
		end
		local player = minetest.get_player_by_name(target)
		if player then
			player:set_hp(value)
		else
			minetest.chat_send_player(name, "Invalid target: " .. target)
		end
	end
})

local function gen_storagekey(pos)
	return string.format("commands@%d|%d|%d", pos.x, pos.y, pos.z)
end

local function initialize_data(meta)
	local commands = minetest.formspec_escape(meta:get_string("commands"))
--[[
	meta:set_string("formspec",
		"size[9,5]" ..
		"textarea[0.5,0.5;8.5,4;commands;Commands;"..commands.."]" ..
		"label[1,3.8;@nearest, @farthest, and @random are replaced by the respective player names]" ..
		"button_exit[3.3,4.5;2,1;submit;Submit]")
]]
	local owner = meta:get_string("owner")
	if owner == "" then
		owner = "not owned"
	else
		owner = "owned by " .. owner
	end
--[[
	meta:set_string("infotext", "Command Block\n" ..
		"(" .. owner .. ")\n" ..
		"Commands: "..commands)
]]
	meta:set_string("infotext", "Command Block\n" ..
		"(" .. owner .. ")")

end

local function construct(pos)
	local meta = minetest.get_meta(pos)

--	meta:set_string("commands", "tell @nearest Commandblock unconfigured")
	mod_storage:set_string(gen_storagekey(pos), "tell @nearest Commandblock unconfigured")

	meta:set_string("owner", "")

	initialize_data(meta)
end

local function after_place(pos, placer)
	if placer then
		local meta = minetest.get_meta(pos)
		meta:set_string("owner", placer:get_player_name())
		initialize_data(meta)
	end
end

local access_pos = {} -- used to keep track of what node a shown formspec corresponds to

--[[
local function receive_fields(pos, _, fields, sender)
	if not fields.submit then
		return
	end
	local meta = minetest.get_meta(pos)
	local owner = meta:get_string("owner")
	if owner ~= "" and sender:get_player_name() ~= owner then
		return
	end
	meta:set_string("commands", fields.commands)

	initialize_data(meta)
end
]]

local access_pos = {} -- used to keep track of what node a shown formspec corresponds to

local function receive_fields(sender, formname, fields)
	if formname ~= "mesecons:commandblock" then
		return false
	end

	local player_name = sender:get_player_name()
	local pos = access_pos[player_name] or nil

	if fields.close or not pos then
		access_pos[player_name] = nil
		minetest.close_formspec(player_name, "mesecons:commandblock")
		return true
	end
	if not fields.submit then
		return true
	end

	local pos = access_pos[player_name]
	local meta = minetest.get_meta(pos)
	local owner = meta:get_string("owner")
	if owner ~= "" and player_name ~= owner then
		return true
	end
--	meta:set_string("commands", fields.commands)
	mod_storage:set_string(gen_storagekey(pos), fields.commands)

	access_pos[player_name] = nil
	minetest.close_formspec(player_name, "mesecons:commandblock")
	return true
end

minetest.register_on_player_receive_fields(receive_fields)

local function old_receive_fields(pos, formname, fields, sender)
	local meta = minetest.get_meta(pos)
	meta:set_string("formspec", "")
end

local function show_formspec(player, pos)
	local meta = minetest.get_meta(pos)
	local owner = meta:get_string("owner")
	local player_name = player:get_player_name()
	local may_view = player_name == owner or not owner

	local r = "invsize[9,5;]"
	if may_view then
		local storagekey = gen_storagekey(pos)
		local commandstring = mod_storage:get_string(storagekey)
		if not commandstring or commandstring == "" then
			commandstring = meta:get_string("commands")
			if commandstring and commandstring ~= "" then
				mod_storage:set_string(storagekey, commandstring)
				meta:set_string("commands", "")
			end
		end
		r = r..
			"textarea[0.5,0.5;8.5,4;commands;Commands;"..commandstring.."]" ..
			"label[1,3.8;@nearest, @farthest, and @random are replaced by the respective player names]" ..
			"button_exit[3.3,4.5;2,1;submit;Submit]"
	else
		r = r..
			"label[1,3.8;only the owner may view and edit the code]" ..
			"button_exit[3.3,4.5;2,1;close;Exit]"
	end

	access_pos[player_name] = pos
	minetest.show_formspec(player_name, "mesecons:commandblock", r)
end

local function resolve_commands(commands, pos)
	local players = minetest.get_connected_players()

	-- No players online: remove all commands containing
	-- @nearest, @farthest and @random
	if #players == 0 then
		commands = commands:gsub("[^\r\n]+", function (line)
			if line:find("@nearest") then return "" end
			if line:find("@farthest") then return "" end
			if line:find("@random") then return "" end
			return line
		end)
		return commands
	end

	local nearest, farthest = nil, nil
	local min_distance, max_distance = math.huge, -1
	for index, player in pairs(players) do
		local distance = vector.distance(pos, player:get_pos())
		if distance < min_distance then
			min_distance = distance
			nearest = player:get_player_name()
		end
		if distance > max_distance then
			max_distance = distance
			farthest = player:get_player_name()
		end
	end
	local random = players[math.random(#players)]:get_player_name()
	commands = commands:gsub("@nearest", nearest)
	commands = commands:gsub("@farthest", farthest)
	commands = commands:gsub("@random", random)
	return commands
end

local function commandblock_action_on(pos, node)
	if node.name ~= "mesecons_commandblock:commandblock_off" then
		return
	end

	minetest.swap_node(pos, {name = "mesecons_commandblock:commandblock_on"})

	local meta = minetest.get_meta(pos)
	local owner = meta:get_string("owner")
	if owner == "" then
		return
	end

--	local commands = resolve_commands(meta:get_string("commands"), pos)
	local commandstring
	if true then
		local storagekey = gen_storagekey(pos)
		commandstring = mod_storage:get_string(storagekey)
		if not commandstring or commandstring == "" then -- handle legacy storage
			commandstring = meta:get_string("commands")
			if commandstring and commandstring ~= "" then
				mod_storage:set_string(storagekey, commandstring)
				meta:set_string("commands", "")
			end
		end
	end

	local commands = resolve_commands(commandstring, pos)
	for _, command in pairs(commands:split("\n")) do
		local pos = command:find(" ")
		local cmd, param = command, ""
		if pos then
			cmd = command:sub(1, pos - 1)
			param = command:sub(pos + 1)
		end
		local cmddef = minetest.chatcommands[cmd]
		if not cmddef then
			minetest.chat_send_player(owner, "The command "..cmd.." does not exist")
			return
		end
		if #param > param_maxlen then
			minetest.chat_send_player(owner, "Command parameters are limited to max. " ..
				param_maxlen .. " bytes.")
			return
		end
		local has_privs, missing_privs = minetest.check_player_privs(owner, cmddef.privs)
		if not has_privs then
			minetest.chat_send_player(owner, "You don't have permission "
					.."to run "..cmd
					.." (missing privileges: "
					..table.concat(missing_privs, ", ")..")")
			return
		end
		cmddef.func(owner, param)
	end
end

local function commandblock_action_off(pos, node)
	if node.name == "mesecons_commandblock:commandblock_on" then
		minetest.swap_node(pos, {name = "mesecons_commandblock:commandblock_off"})
	end
end

local function can_dig(pos, player)
	local meta = minetest.get_meta(pos)
	local owner = meta:get_string("owner")
	return owner == "" or owner == player:get_player_name() or
		minetest.check_player_privs(player, "protection_bypass")
end

local function after_destruct(pos, oldnode)
	mod_storage:set_string(gen_storagekey(pos), "")
end

minetest.register_node("mesecons_commandblock:commandblock_off", {
	description = S("Command Block"),
	tiles = {"jeija_commandblock_off.png"},
	inventory_image = minetest.inventorycube("jeija_commandblock_off.png"),
	is_ground_content = false,
	groups = {cracky=2, mesecon_effector_off=1},
	on_construct = construct,
	after_place_node = after_place,
	after_destruct = after_destruct,
	on_receive_fields = old_receive_fields,
	can_dig = can_dig,
	sounds = mesecon.node_sound.stone,
	mesecons = {effector = {
		action_on = commandblock_action_on
	}},
	on_blast = mesecon.on_blastnode,
	on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
		show_formspec(clicker, pos)
	end
})

minetest.register_node("mesecons_commandblock:commandblock_on", {
	tiles = {"jeija_commandblock_on.png"},
	is_ground_content = false,
	groups = {cracky=2, mesecon_effector_on=1, not_in_creative_inventory=1},
	light_source = 10,
	drop = "mesecons_commandblock:commandblock_off",
	on_construct = construct,
	after_place_node = after_place,
	after_destruct = after_destruct,
	on_receive_fields = old_receive_fields,
	can_dig = can_dig,
	sounds = mesecon.node_sound.stone,
	mesecons = {effector = {
		action_off = commandblock_action_off
	}},
	on_blast = mesecon.on_blastnode,
	on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
		show_formspec(clicker, pos)
	end
})
