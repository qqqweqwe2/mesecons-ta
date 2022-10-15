local GET_COMMAND = "GET"

-- Fan
-- blows objects away
-- The range and strength can be controlled using digiline and formspec

local function fan_make_formspec(pos)
	local meta = minetest.get_meta(pos)
	meta:set_string("formspec", "size[9,3.5]" ..
		"field[0.3,  0;3,2;range;Range (0 to 8):;${range}]"..
		"field[3.3,  0;3,2;strength;Strength (0 to 8):;${strength}]"..
		"field[0.3,1.5;4,2;digiline_channel;Digiline Input Channel (optional):;${digiline_channel}]"..
		"button_exit[7,0.75;2,3;save;Save]")
end

local function fan_on_receive_fields(pos, formname, fields, sender)
	if minetest.is_protected(pos, sender:get_player_name()) then return end

	if not fields["save"] then return end

	local meta = minetest.get_meta(pos)
	meta:set_float("range", math.max(0, math.min(tonumber(fields.range or "") or 5, 8)))
	meta:set_float("strength", math.max(0, math.min(tonumber(fields.strength or "") or 2, 8)))
	meta:set_string("digiline_channel", fields.digiline_channel or "")

	fan_make_formspec(pos)
end

-- applies a fan blow
local function fan_blow(pos)
	local meta = minetest.get_meta(pos)

	local range = meta:get_float("range") or 5
	local strength = meta:get_float("strength") or 2
	local node = minetest.get_node(pos)
	local facedir = node.param2
	local antinormal = minetest.facedir_to_dir(facedir)
	local tangent = {x=1, y=1, z=1}
	for k,v in pairs(antinormal) do
		if v ~= 0 then
			tangent[k] = 0
		end
	end
	local pos1 = vector.subtract(pos, tangent)
	local pos2 = vector.add(vector.add(pos, tangent), vector.multiply(antinormal, -range))
	local objs = minetest.get_objects_in_area(pos1, pos2)

	for _, obj in pairs(objs) do
        local luaentity = obj:get_luaentity()
        if luaentity and luaentity.name or obj:is_player() then
            if obj:is_player() or luaentity.name:find("petz") or luaentity.name:find("builtin") or luaentity.name:find("paleotest") or luaentity.name:find("draconis") then
		        obj:add_velocity(vector.multiply(antinormal, -strength))
            end
        end
	end
end

-- set fan range and/or strength when receiving a digiline signal on a specific channel
local fan_digiline = {
	receptor = {},
	effector = {
		action = function(pos, node, channel, msg)
			local meta = minetest.get_meta(pos)
			if channel == meta:get_string("digiline_channel") then
				if fields and fields.range then
					meta:set_float("range", math.max(0, math.min(tonumber(fields.range) or 5, 8)))
				end
				if fields and fields.strength then
					meta:set_float("strength", math.max(0, math.min(tonumber(fields.strength) or 5, 8)))
				end
				fan_make_formspec(pos)
			end
		end,
	}
}

minetest.register_node("mesecons_fan:fan_off", {
	tiles = {"default_steel_block.png", "default_steel_block.png", "default_steel_block.png^fan_steel_overlay.png", "default_steel_block.png^fan_steel_overlay.png", "default_steel_block.png", "fan_idle.png"},
	paramtype = "light",
	paramtype2 = "facedir",
	is_ground_content = false,
	walkable = true,
	groups = {cracky=3},
	description="Fan",

	mesecons = {effector = { -- activate fan
		action_on = function(pos, node)
			local node = minetest.get_node(pos)
			node.name = "mesecons_fan:fan_on"
			minetest.swap_node(pos, node)
			local timer = minetest.get_node_timer(pos)
			timer:start(0.3)
		end
	}},
	on_construct = function(pos)
		fan_make_formspec(pos)
	end,

	on_receive_fields = fan_on_receive_fields,
	sounds = default.node_sound_stone_defaults(),
	digiline = fan_digiline,
	on_blast = mesecon.on_blastnode,

})

minetest.register_node("mesecons_fan:fan_on", {
	tiles = {
        "default_steel_block.png",
        "default_steel_block.png",
        "default_steel_block.png^fan_steel_overlay.png",
        "default_steel_block.png^fan_steel_overlay.png",
        "default_steel_block.png",
	    {
			name = "fan_animated.png",
			animation = {
				type = "vertical_frames",
				aspect_w = 8,
				aspect_h = 8,
				length = 1.0,
			},
		},
    },
	paramtype = "light",
	paramtype2 = "facedir",
	is_ground_content = false,
	walkable = true,
	groups = {cracky=3,not_in_creative_inventory=1},
	drop = 'mesecons_fan:fan_off',
	mesecons = {effector = { -- deactivate fan
		action_off = function(pos, node)
			local node = minetest.get_node(pos)
			node.name = "mesecons_fan:fan_off"
			minetest.swap_node(pos, node)
		end
	}},
	on_construct = function(pos)
		fan_make_formspec(pos)
		local timer = minetest.get_node_timer(pos)
		timer:start(0.3)
	end,
	on_timer = function(pos)
		fan_blow(pos)
		return true
	end,
	on_receive_fields = fan_on_receive_fields,
	sounds = default.node_sound_stone_defaults(),
	digiline = fan_digiline,
	on_blast = mesecon.on_blastnode,
})

minetest.register_craft({
	output = 'mesecons_fan:fan_off',
	recipe = {
		{"default:steel_ingot", "technic:diamond_drill_head", "default:steel_ingot"},
		{"default:steel_ingot", "technic:motor", "default:steel_ingot"},
		{"default:steel_ingot", "mesecons_luacontroller:luacontroller0000", "default:steel_ingot"},
	}
})
