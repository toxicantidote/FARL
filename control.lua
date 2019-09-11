local version = require('version')
local render = require('render')
local colors = render.colors
local lib = require 'lib_control'
local Position = require 'Position'
local Blueprint = require 'Blueprint'
local round = lib.round
local librail = require 'librail'
local profiler = require('profiler')
local profiler2 = require('profiler2')--luacheck: no unused

local test_runner = require 'tests'
local test_cases = require 'tests.startup'

local dir = defines.direction
local rd = defines.rail_direction

local find_key = lib.find_key

local function print2(v, desc, block)
    local f = block and serpent.block or serpent.line
    print(string.format("%s: %s", desc or "undesc", type(v) == "table" and f(v) or tostring(v)))
end

local log2 = lib.log2

--?Stuff to think about
--[[
    Configuration:
        - as it was
        - simplified: maybe generate the diagonal (maybe a setting for the distance between pole and rail). All the blueprint would need is
          tracks, chain signal/train and pairs of tracks/signal for the other lanes
    Placement modes:
        - classic
        - tileable: blueprints contain multiple rails per lane, should enable grid-like network with farl, with more complex non rail setups:
          (_possibly_ with an alternative blueprint (junction) every X placed tiles)
          Players will have to handle pole distance, FARL will place the next segment when it's close to the end of the current one
                ww          ww      |     ww          ww
            wwwwwwwwwwwwwwwwwwwwwww | wwwwwwwwwwwwwwwwwwwwwww
            ======================= | =======================
                PP          PP      |     PP          PP
            ======================= | =======================
    Signal placement options:
        - by distance, for every lane on it's own
        - by distance, for the main lane only: a curve between 2 signals leads to different block lengths per lane, but keeps the signals positons
          relative to each other the same. Possibly need to slightly overstep the distance if one signal would end up in an invalid position
        - with every pole (keep the offset between pole and signals from the bp), same problem as above, but in that case the distance is limited
          by the poles max wire distance. Overstepping leads to disconnected poles
    Blueprints/Layouts:
        - rotate the 2 required blueprints into the needed directions and use them as lookup tables
          enables customizing each and every direction when desired
    Blueprint parsing:
        - rotate into north/northeast direction
        - allow either a chain signal or a loco to define the direction
        - bounding box
        - group by type/category
        - calculate required offsets rail <-> signal, pole <-> signal, pole <-> other, wall <-> rail
    Selection tool:
        - can be used to increase the clearance area, default to bounding box of entites + some value (2 tiles?)
        - could also be used to quickly configure the layout? Select tracks, signals, poles and the front locomotive (to get rid of the need for a chain signal)
          in simple configuration once is enough, in default select diagonals (loco not necessary i think)
]]


local rcd = {
    left = defines.rail_connection_direction.left,
    right = defines.rail_connection_direction.right,
    straight = defines.rail_connection_direction.straight
}
local drd = defines.riding.direction
local input_2_curve = {[drd.left] = 1, [drd.straight] = 0, [drd.right] = -1}
assert(drd.left == rcd.left)
assert(drd.right == rcd.right)

print("--RCD--")
for k, i in pairs(rcd) do
    if k == "straight" then
        print(k .. "\t" .. i)
    else
        print(k .. "\t\t" .. i)
    end
end

print("\n--RD--")
for k, i in pairs(rd) do
    print(k .. "\t" .. i)
end
local sqrt2 = math.sqrt(2)
local rail_types = lib.create_set("straight-rail", "curved-rail")
local signal_types = lib.create_set("rail-signal", "rail-chain-signal")
local rolling_stock_types = lib.create_set("locomotive", "cargo-wagon", "artillery-wagon", "fluid-wagon")

local curve_length = 7.842081225095 --(get_rail_segment_length() on a curved rail)

local function log_entity(ent, description, short)
    description = description and (description .. ": ") or ""
    if ent and ent.valid then
        local pos = ent.position
        if ent.valid then
            local s = " {x = " .. pos.x .. " y = " .. pos.y .. "}, direction: " .. find_key(dir, ent.direction)
            if short then
                return description .. s
            end
            return description .. "type: " .. ent.type .. s
        else
            log(ent)
            return description .. "Invalid entity"
        end
    end
    return description .. "nil"
end

local function addItemsToCargo(farl, items)--luacheck: no unused
    return
end

local function clear_area(farl, area)
    --! simple-entity isn't necessarily just a rock, could be a modded entity
    local args = {area = area, type = {"tree", "simple-entity", "cliff"}}
    args.limit = 1--?Does that help in any way?
    local count = farl.surface.count_entities_filtered(args)
    if count == 0 then return end
    args.limit = nil
    local amount, name, proto
    local random, ceil = math.random, math.ceil
    local removed = 0
    local to_add = {}
    for _, entity in pairs(farl.surface.find_entities_filtered(args) ) do--, force = "neutral" }) do
        if not entity.valid then goto continue end
        if entity.type == "cliff" then
            if entity.destroy({do_cliff_correction = true}) then
                removed = removed + 1
            end
        else
            proto = entity.prototype.mineable_properties
            if proto and proto.minable and proto.products then
                if (entity.type == "tree" and entity.die(nil, farl.loco)) or entity.destroy() then
                    for _, product in pairs(proto.products) do
                        if product.type == "item" then
                            if product.probability and not product.amount then
                                if product.probability == 1 or (product.probability >= random()) then
                                    name = product.name
                                end
                                if name then
                                    to_add[name] = to_add[name] or 0
                                    if product.amount_max == product.amount_min then
                                        amount = product.amount_max
                                    else
                                        amount = random(product.amount_min, product.amount_max)
                                    end
                                    if amount and amount > 0 then
                                       to_add[name] = to_add[name] + ceil(amount/2)
                                    end
                                    name = false
                                end
                            elseif product.name and product.amount then
                                name = product.name
                                to_add[name] = to_add[name] or 0
                                amount = product.amount
                                if amount and amount > 0 then
                                    to_add[name] = to_add[name] + ceil(amount/2)
                                end
                                name = false
                            end
                        end
                    end
                end
            end
        end
        ::continue::
    end
    addItemsToCargo(farl, to_add)
    --log2(removed, "Removed cliffs")
end

local _rail_data = {}
local hits, calls = 0, 0
local function get_rail_data(rail)
    if rail.valid then
        local id = rail.unit_number
        calls = calls + 1
        if not _rail_data[id] then
            _rail_data[id] = librail.rail_data[rail.type][rail.direction]
        else
            hits = hits + 1
        end
        return _rail_data[id], id
    elseif rail.type and rail.direction then
        return librail.rail_data[rail.type][rail.direction]
    end
end

local chiral_directions = {
        [true] = {
            [rd.front] = rd.front,
            [rd.back] = rd.back
        },
        [false] = {
            [rd.front] = rd.back,
            [rd.back] = rd.front
        }
}
local opposite_rail_direction = chiral_directions[false]

local function create_rail(create_entity, args, surface)
    if surface then
        if not surface.can_place_entity(args) then
            game.print("Can't place: " .. serpent.line(args, {keyignore={force = true}}))
        end
    end
    local c = create_entity(args)
    if c then
        if not Position.equals(args.position, c.position) then
            game.print("Diff: " .. serpent.line(args.position).. " got: " .. serpent.line(c.position))
        end
        return c
    else
        --TODO find_entity and return that maybe?
        game.print("Failed to create: " .. serpent.line(args))
    end
end

local function get_next_rail(rail, travel_rd, input)
    local rdata = get_rail_data(rail)
    local r = rdata.next_rails[travel_rd][input]
    if not r then
        input = rcd.straight
        r = rdata.next_rails[travel_rd][input]
    end
    return r, rdata
end

--first signal
--local _distance = reverse_dir and (distance + s_data.signal.stops) or distance + l - s_data.signal.starts
--best = reverse_dir and (s_data.signal.stops) or (rail_l - s_data.signal.starts)
--second signal
--local _distance = reverse_dir and distance - seg_len + s_data.signal.starts or distance - seg_len + s_data.signal.stops
--best = reverse_dir and (seg_length - (rail_l - s_data.signal.stops)) or (rail_l - s_data.signal.starts)

local function signal_distances(current, signal, length, reverse)
    if reverse then
        return current + length - signal.starts, signal.stops
    else
        return current + signal.stops, length - signal.starts
    end
end

local signal_distance = 13
local function place_signal(farl, position, current_distance, data, signal_dir, create, reverse)
    local signals = data.signals_travel[signal_dir]
    local add_d, new_d
    if reverse then
        local signal
        --log2(signals, "signals r")
        for i = #signals, 1, -1 do
            signal = signals[i]
            add_d, new_d = signal_distances(current_distance, signal, data.length, reverse)
            --log2(add_d, " signal dist r " .. i)
            if add_d >= signal_distance then
                --log2(signal, "signal r")
                create.name = "rail-signal"
                create.direction = signal.d
                create.position = Position.add(position, signal)
                create_rail(farl.surface.create_entity, create, farl.surface)
                --log2(new_d, "length")
                return new_d
            end
        end
    else
        for _, signal in pairs(signals) do
            --log2(current_distance + signal.stops, " signal dist")
            add_d, new_d = signal_distances(current_distance, signal, data.length, reverse)
            if add_d >= signal_distance then
                --log2(signal, "signal")
                create.name = "rail-signal"
                create.direction = signal.d
                create.position = Position.add(position, signal)
                create_rail(farl.surface.create_entity, create, farl.surface)
                --log2(new_d, "length")
                return new_d
            end
        end
    end
    return current_distance + data.length
end

local function place_pole(farl, rail, data, travel_dir, old_data, r_data)--luacheck: no unused
    if not data.main_pole or rail.type == "curved-rail" then return end
    local block = farl.last_curve_input * data.lanes[data.main_pole.lane].block_left
    local pole_pos, pole_distance
        -- log2(travel_dir, "travel_dir")
        -- log2(farl.last_curve_dist, "dist")
        -- log2(block, "block")
    if block - farl.last_curve_dist > 0 then
        -- log2("blocked")
        -- pole_pos = Position.add(lib.diagonal_to_real_pos(rail), data.main_pole.real_pos)
        -- render.draw_circle(pole_pos, nil, colors.black)
        -- if travel_dir % 2 == 0 then
        --     pole_pos = Position.translate(pole_pos, 1, travel_dir)
        --     render.draw_circle(pole_pos, nil, colors.black)
        -- end
        return
    end

    pole_pos = Position.add(lib.diagonal_to_real_pos(rail), data.main_pole.real_pos)
    pole_distance = Position.distance(farl.pole.position, pole_pos)

    if pole_distance >= farl.pole_distance then
        render.draw_circle(pole_pos, nil, nil)
        if pole_distance <= farl.pole_reach then
            farl.pole_candidate.position = pole_pos
            farl.pole_candidate.direction = data.main_pole.direction
            farl.pole_distance = pole_distance
            if travel_dir % 2 == 0 then
                pole_pos = Position.translate(pole_pos, 1, travel_dir)
                pole_distance = Position.distance(farl.pole.position, pole_pos)
                render.draw_circle(pole_pos, nil, colors.blue)

                --seperate case; depending on pole reach we could end up closer to the last pole
                if pole_distance >= farl.pole_distance then
                    if pole_distance <= farl.pole_reach then
                        farl.pole_candidate.position = pole_pos
                        farl.pole_candidate.direction = data.main_pole.direction
                        farl.pole_distance = pole_distance
                    else
                        farl.pole = create_rail(farl.surface.create_entity, farl.pole_candidate, farl.surface)
                        farl.pole_distance = 0
                    end
                end
            end
        else
            farl.pole = create_rail(farl.surface.create_entity, farl.pole_candidate, farl.surface)
            farl.pole_distance = 0
        end
    end
end

local function calculate_area(farl, pos, rail, bb)--luacheck: no unused
    local create = {}
    create.position = Position.add(pos, rail.position)
    create.direction = rail.direction
    create.name = farl.rail_name[rail.type]
    local pos2 = lib.diagonal_to_real_pos(create)
    local area = {left_top = Position.add(pos2, bb.left_top), right_bottom = Position.add(pos2, bb.right_bottom)}
    return area
end

local function clear_curve_area(farl, last_rail, bp_data, is_diagonal, old_travel, last_curve_input, travel_direction)
    local curve_data_old = farl.bp_data[old_travel].curves[last_curve_input]
    local curve_data_o_l = curve_data_old[1]
    local curve_data_o_r = curve_data_old[#bp_data.lanes]
    local pos_l = Position.add(last_rail.position, curve_data_o_l.entrance_pos)
    local pos_r = Position.add(last_rail.position, curve_data_o_r.entrance_pos)

    local bb_l = util.table.deepcopy(bp_data.curves[last_curve_input][1].bb)
    local bb_r = util.table.deepcopy(bp_data.curves[last_curve_input][#bp_data.lanes].bb)

    if last_curve_input == input_2_curve[drd.right] and not is_diagonal then
        lib.rotate_bounding_box(bb_l, dir.east)
        lib.rotate_bounding_box(bb_r, dir.east)
    end

    render.draw_circle(pos_l, nil, colors.green)
    render.draw_circle(pos_r, nil, colors.green)

    if last_curve_input == input_2_curve[drd.right] and not is_diagonal then
        pos_l = Position.translate(pos_l, 1, (travel_direction + 6) % 8)
        pos_r = Position.translate(pos_r, 1, (travel_direction + 6) % 8)
    end

    local tmp_l = Position.add_area(bb_l, pos_l)
    local tmp_r = Position.add_area(bb_r, pos_r)

    --if not is_diagonal then
        render.draw_area(tmp_l, colors.green, {alt = true})
        render.draw_area(tmp_r, colors.green, {alt = true})
        clear_area(farl, tmp_l)
        clear_area(farl, tmp_r)
    --end

    local tmp_bb = {left_top = {x = 0, y = 0}, right_bottom = {x = 0, y = 0}}
    local amount = is_diagonal and 1 or 3
    for i = 1, amount do
        pos_l = Position.translate(pos_l, 1, old_travel)
        pos_r = Position.translate(pos_r, 1, old_travel)
        if is_diagonal then
            Position.merge_area(tmp_l, Position.add_area(bb_l, pos_l, tmp_bb))
            Position.merge_area(tmp_r, Position.add_area(bb_r, pos_r, tmp_bb))
        else
            tmp_l = Position.add_area(bb_l, pos_l, tmp_l)
            tmp_r = Position.add_area(bb_r, pos_r, tmp_r)
        end
        render.draw_area(tmp_l, colors.green, {alt = true})
        render.draw_area(tmp_r, colors.green, {alt = true})
        clear_area(farl, tmp_l)
        clear_area(farl, tmp_r)
    end

    bb_l = util.table.deepcopy(bp_data.curves[last_curve_input][1].bb2)
    bb_r = util.table.deepcopy(bp_data.curves[last_curve_input][#bp_data.lanes].bb2)

    pos_l = Position.add(last_rail.position, curve_data_o_l.exit_pos)
    pos_r = Position.add(last_rail.position, curve_data_o_r.exit_pos)

    if last_curve_input == input_2_curve[drd.left] then
        if is_diagonal then
            lib.rotate_bounding_box(bb_l, dir.east)
            lib.rotate_bounding_box(bb_r, dir.east)
            pos_l = Position.translate(pos_l, 1, (travel_direction + 7) % 8)
            pos_r = Position.translate(pos_r, 1, (travel_direction + 7) % 8)
        end
    end
    tmp_l = Position.add_area(bb_l, pos_l)
    tmp_r = Position.add_area(bb_r, pos_r)

    if is_diagonal then
        render.draw_area(tmp_l, colors.black, {alt = true})
        render.draw_area(tmp_r, colors.black, {alt = true})
        clear_area(farl, tmp_l)
        clear_area(farl, tmp_r)
    end

    amount = is_diagonal and 4 or 1
    -- local block_l = farl.bp_data[old_travel].lanes[1].distance
    -- local block_r = farl.bp_data[old_travel].lanes[#bp_data.lanes].distance
    -- local l_l = farl.bp_data[old_travel].lanes[1].lag_s * - farl.last_curve_input
    -- local l_r = farl.bp_data[old_travel].lanes[#bp_data.lanes].lag_s * - farl.last_curve_input
    log2(farl.bp_data[old_travel].curves[last_curve_input][1].foo, "foo l")
    log2(farl.bp_data[old_travel].curves[last_curve_input][#bp_data.lanes].foo, "foo r")
    log2(bp_data.curves[last_curve_input][1].foo, "foo l new")
    log2(bp_data.curves[last_curve_input][#bp_data.lanes].foo, "foo r new")
    local pos_l_o = Position.add(last_rail.position, curve_data_o_l.exit_pos)
    local pos_r_o = Position.add(last_rail.position, curve_data_o_r.exit_pos)
    local _pos
    for _, _data in pairs({
        {foo = bp_data.curves[last_curve_input][1].foo, pos = pos_l_o, bb = bb_l},
        {foo = bp_data.curves[last_curve_input][#bp_data.lanes].foo, pos = pos_r_o, bb = bb_r}}) do
        local _bb = util.table.deepcopy(_data.bb)
        _pos = _data.pos
        if last_curve_input == input_2_curve[drd.left] then
            if is_diagonal then
                lib.rotate_bounding_box(_bb, dir.west)
                _pos = Position.translate(_pos, -2, travel_direction)
            end
        end

        for i = 1, _data.foo do
            _pos = Position.translate(_pos, is_diagonal and 1 or 2, travel_direction)
            render.draw_circle(_pos, nil, colors.orange)
            tmp_l = Position.add_area(_bb, _pos, tmp_l)
            render.draw_area(tmp_l, colors.red)
        end
    end
    for i = 1, amount do
        pos_l = Position.translate(pos_l, -1, travel_direction)
        pos_r = Position.translate(pos_r, -1, travel_direction)
        if i == amount then
            pos_l = Position.translate(pos_l, 0.5, travel_direction)
            pos_r = Position.translate(pos_r, 0.5, travel_direction)
        end
        if not is_diagonal then
            Position.merge_area(tmp_l, Position.add_area(bb_l, pos_l, tmp_bb))
            Position.merge_area(tmp_r, Position.add_area(bb_r, pos_r, tmp_bb))
        else
            tmp_l = Position.add_area(bb_l, pos_l, tmp_l)
            tmp_r = Position.add_area(bb_r, pos_r, tmp_r)
        end
        render.draw_area(tmp_l, colors.black, {alt = true})
        render.draw_area(tmp_r, colors.black, {alt = true})
        clear_area(farl, tmp_l)
        clear_area(farl, tmp_r)
    end
end

local function place_next_rail(farl, input, data, same_input)
    local c
    local surface = farl.surface
    local pos = farl.last_rail.position
    local create = {force = farl.force, position = Position.add(pos, {x=0,y=0}), direction = 0, name = false}
    local rail, rdata = get_next_rail(farl.last_rail, farl.travel_rd, input)

    if rail then
        create.position = Position.add(pos, rail.position)
        create.direction = rail.direction
        create.name = farl.rail_name[rail.type]

        local bb = data.bounding_box
        local de_pos = lib.diagonal_to_real_pos(create)
        local area = {left_top = Position.add(de_pos, bb.left_top), right_bottom = Position.add(de_pos, bb.right_bottom)}
        --render.draw_rectangle(area.left_top, area.right_bottom, colors.blue, true)
        if rail.type == "curved-rail" then
            local ndata = get_rail_data(rail)
            local new_travel = ndata.rd_to_travel[chiral_directions[rdata.chirality == ndata.chirality][farl.travel_rd]]
            if #data.lanes > 1 then
                local clear_a = librail.rail_data["curved-rail"][rail.direction].clear_area
                local _ca = {
                    left_top = Position.add(clear_a.left_top, create.position),
                    right_bottom = Position.add(clear_a.right_bottom, create.position)}
                render.draw_area(_ca, colors.red)
                clear_area(farl, _ca)
            end

            clear_curve_area(farl, create, data, farl.travel_direction % 2 == 0, farl.travel_direction, input_2_curve[input], new_travel)

        else
            --farl.bb = render.draw_rectangle(area.left_top, area.right_bottom, colors.green, nil, {id = farl.bb})
            render.draw_rectangle(area.left_top, area.right_bottom, colors.blue, true)
            clear_area(farl, area)
        end
        c = create_rail(surface.create_entity, create, farl.surface)
        if not c then
            return
        end
        local ndata = get_rail_data(c)
        local chiral = chiral_directions[rdata.chirality == ndata.chirality][farl.travel_rd]
        local new_travel = ndata.rd_to_travel[chiral]

        --TODO place signal and depending on signal placement option trigger signal placement for lanes (if signals should be placed relative to the main signal)
        farl.dist = place_signal(farl, c.position, farl.dist, ndata, new_travel, create)

        place_pole(farl, c, farl.bp_data[new_travel], new_travel, data, ndata)

        --render.mark_entity_text(c, round(farl.dist, 1), nil, {top = true})
        if rail.type == "curved-rail" then
            if data.main_pole then
                local catchup = data.lanes[data.main_pole.lane].block_left * - input_2_curve[input] / 2
                log2(catchup, "catchup1")
                if catchup >= 0 then
                    if not same_input then
                        catchup = farl.last_curve_dist > catchup and catchup or farl.last_curve_dist
                    end
                    log2(catchup, "catchup")
                    if new_travel % 2 == 1 then
                        catchup = catchup * 2
                    end
                    --? always catchup one position more?
                    catchup = catchup + 1
                    log2(farl.pole_candidate)
                    local pole_pos = farl.pole_candidate.position
                    local pole_distance
                    local p = farl.pole.position
                    for i = 1, catchup do
                        pole_pos = Position.translate(pole_pos, 1, farl.travel_direction)
                        pole_distance = Position.distance(pole_pos, p)
                        render.draw_circle(pole_pos, nil, colors.orange)
                        if pole_distance <= farl.pole_reach then
                            farl.pole_candidate.position = pole_pos
                            farl.pole_candidate.direction = data.main_pole.direction
                            farl.pole_distance = pole_distance
                        else
                            farl.pole = create_rail(farl.surface.create_entity, farl.pole_candidate, farl.surface)
                            p = farl.pole.position
                            farl.pole_distance = 0
                        end
                    end
                end
            end
        end
        return c, chiral, new_travel, input
    end
end

local function place_parallel_rails(farl, data)
    local c
    local pos = farl.last_rail.position
    local create_entity = farl.surface.create_entity
    local create = {force = farl.force, position = {x=0,y=0}, direction = 0, name = farl.rail_name["straight-rail"]}
    local same_dir = farl.last_rail.direction == data.main_rail.direction
    local block, ndata
    for li, lane in pairs(data.lanes) do
        if not lane.main then
            block = farl.last_curve_input * lane.block_left
            --log2(block, "block " .. li)
            if block - farl.last_curve_dist < 0 then
                create.position = Position.add(pos, lane.position)
                create.direction = same_dir and lane.direction or (lane.direction + 4) % 8
                c = create_rail(create_entity, create, farl.surface)
                if c then
                    ndata = get_rail_data(c)
                    local signal_dir = lane.travel_dir
                    local distance = farl.last_lanes[li].dist + ndata.length
                    if lane.travel_dir then
                        distance = place_signal(farl, c.position, farl.last_lanes[li].dist, ndata, signal_dir, create, signal_dir ~= farl.travel_direction)
                        create.name = farl.rail_name["straight-rail"]
                    end
                    farl.last_lanes[li].rail = c
                    farl.last_lanes[li].dist = distance
                    --render.mark_entity(c, nil, tostring(block))
                    --render.mark_entity_text(c, round(farl.last_lanes[li].dist, 1), nil, {top = true})
                end
            end
        end
    end
end

local function place_parallel_curves(farl, bp_data, input, old_travel, same_input, old_rail)--luacheck: no unused
    local catchup
    local pos, rail, data, ndata
    --local is_diagonal = farl.travel_direction % 2 == 1
    local create_entity = farl.surface.create_entity
    local create = {force = farl.force, position = {}, direction = 0, name = false}
    log2(farl.last_curve_input, "last input")
    local bb1 = farl.last_curve_input == -1 and bp_data.bb_l or bp_data.bb_r
    local bb2 = farl.last_curve_input == -1 and bp_data.bb_r or bp_data.bb_l
    local which2 = farl.last_curve_input == -1 and 1 or #bp_data.lanes
    local which3 = farl.last_curve_input == -1 and #bp_data.lanes or 1
    local clear_c1 = bp_data.lanes[which2].block_left * - farl.last_curve_input
    local clear_c2 = bp_data.lanes[which3].block_left * - farl.last_curve_input
    clear_c1 = clear_c1 < 0 and 0 or clear_c1
    --clear_c2 = clear_c2 < 0 and 2 or clear_c2 + 2
    clear_c2 = old_travel % 2 == 1 and 0 or clear_c2
    if farl.last_curve_input == input_2_curve[drd.left] then
        clear_c1 = clear_c1 - 2
    end
    log2(bb1, "bb_l/r")
    for _, clear_data in pairs{{c = clear_c1, bb = bb1}, {c = clear_c2, bb = bb2}} do
        local clear_c = clear_data.c
        local bb = clear_data.bb
        if not same_input then
            clear_c = farl.last_curve_dist > clear_c and clear_c or farl.last_curve_dist
        end
        log2(clear_c, "catchup " .. _)

        --local c_rail = old_rail
        local area, c_pos, c_rail_d
        create.name = farl.rail_name["straight-rail"]
        create.position = old_rail.position
        create.direction = old_rail.direction
        create.type = "straight-rail"
        for i = 1, clear_c do
            data = get_rail_data(create)
            c_rail_d = data.next_rails[data.travel_to_rd[old_travel]][defines.riding.direction.straight]
            create.position = Position.add(create.position, c_rail_d.position)
            create.direction = c_rail_d.direction

            render.draw_circle(create.position, nil, colors.red, true)
            c_pos = lib.diagonal_to_real_pos(create)
            area = {left_top = Position.add(c_pos, bb.left_top), right_bottom = Position.add(c_pos, bb.right_bottom)}
            render.draw_area(area, colors.red)
            clear_area(farl, area)
        end
        create.type = nil
    end

    -- local curve_data_old = farl.bp_data[old_travel].curves[farl.last_curve_input]
    -- local curve_data_o_l = curve_data_old[1]
    -- local curve_data_o_r = curve_data_old[#bp_data.lanes]
    -- local pos_l = Position.add(farl.last_rail.position, curve_data_o_l.entrance_pos)
    -- local pos_r = Position.add(farl.last_rail.position, curve_data_o_r.entrance_pos)

    -- local bb_l = util.table.deepcopy(bp_data.curves[farl.last_curve_input][1].bb)
    -- local bb_r = util.table.deepcopy(bp_data.curves[farl.last_curve_input][#bp_data.lanes].bb)

    -- if farl.last_curve_input == input_2_curve[drd.right] and not is_diagonal then
    --     lib.rotate_bounding_box(bb_l, dir.east)
    --     lib.rotate_bounding_box(bb_r, dir.east)
    -- end

    -- render.draw_circle(pos_l, nil, colors.green)
    -- render.draw_circle(pos_r, nil, colors.green)

    -- if farl.last_curve_input == input_2_curve[drd.right] and not is_diagonal then
    --     pos_l = Position.translate(pos_l, 1, (farl.travel_direction + 6) % 8)
    --     pos_r = Position.translate(pos_r, 1, (farl.travel_direction + 6) % 8)
    -- end

    -- local tmp_l = Position.add_area(bb_l, pos_l)
    -- local tmp_r = Position.add_area(bb_r, pos_r)

    -- --if not is_diagonal then
    --     render.draw_area(tmp_l, colors.green, {alt = true})
    --     render.draw_area(tmp_r, colors.green, {alt = true})
    --     clear_area(farl, tmp_l)
    --     clear_area(farl, tmp_r)
    -- --end

    -- local tmp_bb = {left_top = {x = 0, y = 0}, right_bottom = {x = 0, y = 0}}
    -- local amount = is_diagonal and 1 or 3
    -- for i = 1, amount do
    --     pos_l = Position.translate(pos_l, 1, old_travel)
    --     pos_r = Position.translate(pos_r, 1, old_travel)
    --     if is_diagonal then
    --         Position.merge_area(tmp_l, Position.add_area(bb_l, pos_l, tmp_bb))
    --         Position.merge_area(tmp_r, Position.add_area(bb_r, pos_r, tmp_bb))
    --     else
    --         tmp_l = Position.add_area(bb_l, pos_l, tmp_l)
    --         tmp_r = Position.add_area(bb_r, pos_r, tmp_r)
    --     end
    --     render.draw_area(tmp_l, colors.green, {alt = true})
    --     render.draw_area(tmp_r, colors.green, {alt = true})
    --     clear_area(farl, tmp_l)
    --     clear_area(farl, tmp_r)
    -- end

    -- bb_l = util.table.deepcopy(bp_data.curves[farl.last_curve_input][1].bb2)
    -- bb_r = util.table.deepcopy(bp_data.curves[farl.last_curve_input][#bp_data.lanes].bb2)

    -- pos_l = Position.add(farl.last_rail.position, curve_data_o_l.exit_pos)
    -- pos_r = Position.add(farl.last_rail.position, curve_data_o_r.exit_pos)

    -- if farl.last_curve_input == input_2_curve[drd.left] then
    --     if is_diagonal then
    --         lib.rotate_bounding_box(bb_l, dir.east)
    --         lib.rotate_bounding_box(bb_r, dir.east)
    --         pos_l = Position.translate(pos_l, 1, (farl.travel_direction + 7) % 8)
    --         pos_r = Position.translate(pos_r, 1, (farl.travel_direction + 7) % 8)
    --     end
    -- end
    -- tmp_l = Position.add_area(bb_l, pos_l)
    -- tmp_r = Position.add_area(bb_r, pos_r)

    -- if is_diagonal then
    --     render.draw_area(tmp_l, colors.black, {alt = true})
    --     render.draw_area(tmp_r, colors.black, {alt = true})
    --     clear_area(farl, tmp_l)
    --     clear_area(farl, tmp_r)
    -- end

    -- amount = is_diagonal and 4 or 1
    -- -- local block_l = farl.bp_data[old_travel].lanes[1].distance
    -- -- local block_r = farl.bp_data[old_travel].lanes[#bp_data.lanes].distance
    -- -- local l_l = farl.bp_data[old_travel].lanes[1].lag_s * - farl.last_curve_input
    -- -- local l_r = farl.bp_data[old_travel].lanes[#bp_data.lanes].lag_s * - farl.last_curve_input
    -- log2(farl.bp_data[old_travel].curves[farl.last_curve_input][1].foo, "foo l")
    -- log2(farl.bp_data[old_travel].curves[farl.last_curve_input][#bp_data.lanes].foo, "foo r")
    -- log2(bp_data.curves[farl.last_curve_input][1].foo, "foo l new")
    -- log2(bp_data.curves[farl.last_curve_input][#bp_data.lanes].foo, "foo r new")
    -- local pos_l_o = Position.add(farl.last_rail.position, curve_data_o_l.exit_pos)
    -- local pos_r_o = Position.add(farl.last_rail.position, curve_data_o_r.exit_pos)
    -- local _pos
    -- for _, _data in pairs({
    --     {foo = bp_data.curves[farl.last_curve_input][1].foo, pos = pos_l_o, bb = bb_l},
    --     {foo = bp_data.curves[farl.last_curve_input][#bp_data.lanes].foo, pos = pos_r_o, bb = bb_r}}) do
    --     local _bb = util.table.deepcopy(_data.bb)
    --     _pos = _data.pos
    --     if farl.last_curve_input == input_2_curve[drd.left] then
    --         if is_diagonal then
    --             lib.rotate_bounding_box(_bb, dir.west)
    --             _pos = Position.translate(_pos, -2, farl.travel_direction)
    --         end
    --     end

    --     for i = 1, _data.foo do
    --         _pos = Position.translate(_pos, is_diagonal and 1 or 2, farl.travel_direction)
    --         render.draw_circle(_pos, nil, colors.orange)
    --         tmp_l = Position.add_area(_bb, _pos, tmp_l)
    --         render.draw_area(tmp_l, colors.red)
    --     end
    -- end
    -- for i = 1, amount do
    --     pos_l = Position.translate(pos_l, -1, farl.travel_direction)
    --     pos_r = Position.translate(pos_r, -1, farl.travel_direction)
    --     if i == amount then
    --         pos_l = Position.translate(pos_l, 0.5, farl.travel_direction)
    --         pos_r = Position.translate(pos_r, 0.5, farl.travel_direction)
    --     end
    --     if not is_diagonal then
    --         Position.merge_area(tmp_l, Position.add_area(bb_l, pos_l, tmp_bb))
    --         Position.merge_area(tmp_r, Position.add_area(bb_r, pos_r, tmp_bb))
    --     else
    --         tmp_l = Position.add_area(bb_l, pos_l, tmp_l)
    --         tmp_r = Position.add_area(bb_r, pos_r, tmp_r)
    --     end
    --     render.draw_area(tmp_l, colors.black, {alt = true})
    --     render.draw_area(tmp_r, colors.black, {alt = true})
    --     clear_area(farl, tmp_l)
    --     clear_area(farl, tmp_r)
    -- end

    for li, lane in pairs(farl.last_lanes) do
        catchup = bp_data.lanes[li].block_left * - farl.last_curve_input
        local c = lane.rail
        if catchup > 0 and c.valid then
            if not same_input then
                catchup = farl.last_curve_dist > catchup and catchup or farl.last_curve_dist
            end
            for i = 1, catchup do
                pos = c.position
                data = get_rail_data(c)
                rail = data.next_rails[data.travel_to_rd[old_travel]][defines.riding.direction.straight]

                if rail then
                    create.position = Position.add(pos, rail.position)
                    create.name = farl.rail_name["straight-rail"]
                    create.direction = rail.direction
                    c = create_rail(create_entity, create, farl.surface)
                    if c then
                        ndata = get_rail_data(c)

                        local signal_dir = bp_data.lanes[li].travel_dir
                        local distance = lane.dist + ndata.length
                        if bp_data.lanes[li].travel_dir then
                            distance = place_signal(farl, c.position, lane.dist, ndata, signal_dir, create, signal_dir ~= old_travel)
                        end
                        lane.rail = c
                        lane.dist = distance
                        --render.mark_entity_text(c, lane.dist, nil, {top = true})
                    end
                end
            end
        end
        data = get_rail_data(farl.last_lanes[li].rail)
        rail = data.next_rails[data.travel_to_rd[old_travel]][input]
        if rail then
            pos = farl.last_lanes[li].rail.position
            create.position = Position.add(pos, rail.position)
            create.name = farl.rail_name["curved-rail"]
            create.direction = rail.direction

            c = create_rail(create_entity, create, farl.surface)
            if c then
                local cdata = farl.bp_data[farl.travel_direction]
                ndata = get_rail_data(c)
                -- log2(ndata.signals_travel, "signals")
                -- log2(farl.travel_direction, "farl td")
                -- log2(old_travel, "old_travel")
                local reverse = cdata.lanes[li].travel_dir ~= farl.travel_direction
                local signal_dir = reverse and farl.bp_data[old_travel].lanes[li].travel_dir or  farl.travel_direction
                -- log2(bp_data.lanes[li].travel_dir, "lane td")
                -- log2(signal_dir, "signal_dir")
                local distance = lane.dist + ndata.length
                if signal_dir then
                    log2(distance, "current dist")
                    log2(distance + ndata.length, "max dist")
                    distance = place_signal(farl, c.position, lane.dist, ndata, signal_dir, create, reverse)
                    -- log2(distance, "dist")
                    -- log2(distance + ndata.length, "new dist")
                end

                farl.last_lanes[li].rail = c
                farl.last_lanes[li].dist = distance
                --farl.last_lanes[li].dist = distance + ndata.length
                --render.mark_entity_text(c, farl.last_lanes[li].dist, nil, {top = true})
            end
        end
    end
end

local function on_tick()
    local changed
    for train_id, farl in pairs(global.active) do
        if not (farl.player and farl.player.valid and farl.last_rail and farl.last_rail.valid and farl.loco and farl.loco.valid) then
            global.active[train_id] = nil
            changed = true
            goto continue
        end
        --{last_rail = dead_end, distance = distance, player = player, loco = loco}
        if Position.distance_squared(farl.last_rail.position, farl.loco.position) < 36 then
            local input = farl.driver.riding_state.direction
            local data = farl.bp_data[farl.travel_direction]
            assert(data)
            local i2c = input_2_curve[input]
            if input ~= drd.straight and i2c == farl.last_curve_input and farl.last_curve_dist < data.curve_block[i2c] then
                    input = drd.straight
            end

            render.on(true)
            render.surface = farl.surface
            local old_travel = farl.travel_direction
            local old_curve = farl.last_curve_input
            local old_rail = farl.last_rail
            local new_rail, new_rd, new_travel, actual_input = place_next_rail(farl, input, data, farl.last_curve_input == old_curve)
            if new_rail then
                farl.last_rail, farl.travel_rd, farl.travel_direction = new_rail, new_rd, new_travel
                if new_rail.type == "straight-rail" then
                    farl.last_curve_dist = farl.last_curve_dist + 1
                    place_parallel_rails(farl, data)
                else
                    farl.last_curve_input = input_2_curve[actual_input]
                    place_parallel_curves(farl, data, actual_input, old_travel, farl.last_curve_input == old_curve, old_rail)
                    farl.last_curve_dist = 0
                end
                farl.line = render.draw_line(farl.loco, farl.loco, colors.red, false, false, {id = farl.line,
                                from_offset = Position.rotate({x = -1, y = -6}, new_travel * 45),
                                to_offset = Position.rotate({x = 1, y = -6}, new_travel * 45)
                            })
            else
                game.print("Deactivate")
                farl.last_rail = nil
            end

            render.restore()
        end

        ::continue::
    end
    if changed and table_size(global.active) == 0 then
        script.on_event(defines.events.on_tick, nil)
        log("Unregistered")
    end
end

local function init_global()
    global = global or {}
    global._pdata = global._pdata or {}
    global.active = global.active or {}
end

local function init_player(index)
    local pdata = global._pdata[index] or {}
    pdata.bp_data = pdata.bp_data or {}


    global._pdata[index] = pdata
end

local function on_init()
    log("on_init")
    init_global()
    for index, _ in pairs(game.players) do
        init_player(index)
    end
end

local function on_load()
    log("on_load")
    if table_size(global.active) > 0 then
        script.on_event(defines.events.on_tick, on_tick)
        log("Registered")
    else
        script.on_event(defines.events.on_tick, nil)
        log("Unregistered")
    end
end

local function on_configuration_changed(data)
    log("on_config_changed")
    if not data then
        return
    end
    log("on_config_changed data: " .. serpent.block(data))
    if data.mod_changes.FARL then
        local oldVersion = data.mod_changes.FARL.old_version
        local newVersion = data.mod_changes.FARL.new_version
        if oldVersion then
            log("FARL version changed from ".. tostring(oldVersion) .." to ".. tostring(newVersion))
            oldVersion = oldVersion and version.parse(oldVersion)
            newVersion = version.parse(newVersion)
            if version.lt(newVersion, oldVersion) then
                log("Downgrading FARL")
                global = {}
                on_init()
            end
            on_init()
            on_load()
        end
    end
end

local function on_player_created(event)
    init_player(game.get_player(event.player_index))
end

local function on_gui_click(event)
    if event.element.name == "farl_code_close" then
        event.element.parent.parent.destroy()
        return
    end
    if event.element.name == "farl_code_ok" then
        local txt = tonumber(event.element.parent.farl_test_index.text)
        global.tests_created = (txt or global.tests_created) + 1
        event.element.parent.parent.destroy()
        return
    end

end

local function on_gui_checked_state_changed()

end

local function on_preplayer_mined_item()

end

local function on_marked_for_deconstruction()
    on_preplayer_mined_item()
end

local function on_entity_died()
    on_preplayer_mined_item()
end

librail.rail_data = {
    ["straight-rail"] = {
        [dir.north] = {
            length = 2,
            travel_to_rd = {
                [dir.north] = rd.front,
                [dir.south] = rd.back
            },
            rd_to_travel = {
                [rd.front] = dir.north,
                [rd.back] = dir.south
            },
            signals = {
                    [rd.front] = {
                        --stops: add to current signal distance, too see if it needs to be placed
                        --starts: subtract from length to get the new signal distance
                        {x=1.5, y= 0.5, d=dir.south, stops=-1, starts=0},  -- Train stops 1 unit before this rail begins
                        {x=1.5, y=-0.5, d=dir.south, stops=1, starts=2}
                    },
                    [rd.back] = {
                        --REVERSE case:
                        --stops: new signal distance
                        --starts: add length - starts to signal distance for check
                        {x=-1.5, y=-0.5, d=dir.north, stops=-1, starts=0},
                        {x=-1.5, y= 0.5, d=dir.north, stops=1, starts=2},
                    },
            },
            next_rails = {
                [rd.front] = {
                    [rcd.left] = {type = "curved-rail", direction = dir.north, position = {x = -1, y = -5}},
                    [rcd.straight] = {type = "straight-rail", direction = dir.north, position = {x = 0, y = -2}},
                    [rcd.right] = {type = "curved-rail", direction = dir.northeast, position = {x = 1, y = -5}}
                },
                [rd.back] = {
                    [rcd.left] = {type = "curved-rail", direction = dir.south, position = {x = 1, y = 5}},
                    [rcd.straight] = {type = "straight-rail", direction = dir.north, position = {x = 0, y = 2}},
                    [rcd.right] = {type = "curved-rail", direction = dir.southwest, position = {x = -1, y = 5}}
                }
            },
        },
        [dir.northeast] = {
            length = sqrt2,
            travel_to_rd = {
                [dir.northwest] = rd.front,
                [dir.southeast] = rd.back
            },
            rd_to_travel = {
                [rd.front] = dir.northwest,
                [rd.back] = dir.southeast
            },
            signals = {
                [rd.front] = {{x=1.5, y=-1.5, d=dir.southeast, stops=-1, starts=sqrt2}},
                [rd.back] = {{x=-0.5, y=0.5, d=dir.northwest, stops=0, starts=sqrt2}},
                -- [rd.front] = {{x=1.5, y=-1.5, d=dir.southeast, stops=-1, starts=1}},
                -- [rd.back] = {{x=-0.5, y=0.5, d=dir.northwest, stops=0, starts=1}},
            },
            next_rails = {
                [rd.front] = {
                    [rcd.left] = {type = "curved-rail", direction = dir.southeast, position = {x = -3, y = -3}},
                    [rcd.straight] = {type = "straight-rail", direction = dir.southwest, position = {x = 0, y = -2}},
                    --?diagonals only have 2 possible connections, not sure how to handle that yet
                    --If we detect a right input, place the next diagonal track AND the curve or only the diagonal
                    --and do the curve in the next tick/step?
                    [rcd.right] = nil--{type = "curved-rail", direction = dir.northeast, position = {x = 1, y = -5}}
                },
                [rd.back] = {
                    [rcd.left] = nil, --{type = "curved-rail", direction = dir.south, position = {x = 1, y = 5}},
                    [rcd.straight] = {type = "straight-rail", direction = dir.southwest, position = {x = 2, y = 0}},
                    [rcd.right] = {type = "curved-rail", direction = dir.north, position = {x = 3, y = 3}}
                }
            },
        },
    },
    ["curved-rail"] = {
        [dir.north] = {
            length = curve_length,
            travel_to_rd = {
                [dir.northwest] = rd.back,
                [dir.south] = rd.front
            },
            exit_rails = {
                [dir.northwest] = {position = {x = -1, y = -3}, direction = dir.southwest, type = "straight-rail"},
                [dir.south] = {position = {x = 1, y = 3}, direction = dir.north, type = "straight-rail"}
            },
            rd_to_travel = {
                [rd.front] = dir.south,
                [rd.back] = dir.northwest
            },
            signals = {
                [rd.front] = {
                    {x=-2.5, y=-1.5, d=dir.northwest, stops=-1, starts=0},
                    {x=-0.5, y=3.5, d=dir.north, stops=curve_length-1, starts=curve_length}
                },
                [rd.back] = {
                    {x=2.5, y=3.5, d=dir.south, stops=-1, starts=0},
                    {x=-0.5, y=-3.5, d=dir.southeast, stops=curve_length-1, starts=curve_length}
                },
            },
            next_rails = {
                [rd.front] = {
                    [rcd.left] = {type = "curved-rail", direction = dir.south, position = {x = 2, y = 8}},
                    [rcd.straight] = {type = "straight-rail", direction = dir.north, position = {x = 1, y = 5}},
                    [rcd.right] = {type = "curved-rail", direction = dir.southwest, position = {x = 0, y = 8}}
                },
                [rd.back] = {
                    [rcd.left] = nil, --{type = "curved-rail", direction = dir.south, position = {x = 1, y = 5}},
                    [rcd.straight] = {type = "straight-rail", direction = dir.northeast, position = {x = -3, y = -3}},
                    [rcd.right] = {type = "curved-rail", direction = dir.south, position = {x = -4, y = -6}}
                }
            },
            clear_area = {
                left_top = {x = -2.5, y = -3.5},
                right_bottom = {x = 2, y = 4},
            },
        },
        [dir.northeast] = {
            length = curve_length,
            travel_to_rd = {
                [dir.northeast] = rd.back,
                [dir.south] = rd.front
            },
            exit_rails = {
                --[new travel dir]
                [dir.northeast] = {position = {x = 1, y = -3}, direction = dir.southeast, type = "straight-rail"},
                [dir.south] = {position = {x = -1, y = 3}, direction = dir.north, type = "straight-rail"}
            },
            rd_to_travel = {
                [rd.front] = dir.south,
                [rd.back] = dir.northeast
            },
            signals = {
                [rd.front] = {
                    {x=0.5, y=-3.5, d=dir.northeast, stops=-1, starts=0},
                    {x=-2.5, y=3.5, d=dir.north, stops=curve_length-1, starts=curve_length},
                },
                [rd.back] = {
                    {x=0.5, y=3.5, d=dir.south, stops=-1, starts=0},
                    {x=2.5, y=-1.5, d=dir.southwest, stops=curve_length-1, starts=curve_length},
                },
            },
            next_rails = {
                [rd.front] = {
                    [rcd.left] = {type = "curved-rail", direction = dir.south, position = {x = 0, y = 8}},
                    [rcd.straight] = {type = "straight-rail", direction = dir.north, position = {x = -1, y = 5}},
                    [rcd.right] = {type = "curved-rail", direction = dir.southwest, position = {x = -2, y = 8}}
                },
                [rd.back] = {
                    [rcd.left] = {type = "curved-rail", direction = dir.southwest, position = {x = 4, y = -6}},
                    [rcd.straight] = {type = "straight-rail", direction = dir.northwest, position = {x = 3, y = -3}},
                    [rcd.right] = nil
                }
            },
            clear_area = {
                left_top = {x = -2, y = -3.5},
                right_bottom = {x = 2.5, y = 4}
            },
        },
    }
}

librail.create_lookup()

-- local function get_rail_data(rail)
--     return next_rail_data[rail.type][rail.direction]
-- end
-- local k = librail.args_to_key(signal.position.x - dead_end.position.x, signal.position.y - dead_end.position.y, signal.direction)
--                         local temp = data.signal_map[k]
--                         log2(serpent.block(temp), "The one")
local function get_signal_data2(signal, ent)--luacheck: no unused
    local data = librail.signal_data[signal.direction]
    local k = librail.args_to_key(ent.position.x - signal.position.x, ent.position.y - signal.position.y, ent.direction)
    --print(tostring(k))
    local tmp = data.rail_map[ent.type][k]
    if tmp then
        -- log2(serpent.block(tmp, {keyignore={rail_data = true}}))
        return tmp
    end
end

local function get_signal_data(signal, rail, rail2)--luacheck: no unused
    local signal_data = get_rail_data(rail).signal_map
    local signal_pos = signal.position
    local signal_dir = signal.direction
    local rail_pos = rail.position
    local rail_dir = rail.direction
    rail_pos = {x = rail_pos.x, y = rail_pos.y}
    local k = librail.args_to_key(signal_pos.x - rail_pos.x, signal_pos.y - rail_pos.y, signal_dir)
    local t = signal_data[k]
    local hit = t and rail
    -- print(tostring(k))
    -- if t then
    --     print(serpent.block(t, {keyignore={rail_data = true}}))
    -- end
    -- local _ = get_signal_data2(signal, rail2)
    --print(serpent.block(test))
    --assert(table.compare(t, test), string.format("%s not equal to %s", tostring(t), tostring(test)))

    if (not t) and rail2 then
        signal_data = get_rail_data(rail2).signal_map
        rail_pos = rail2.position
        rail_pos = {x = rail_pos.x, y = rail_pos.y}
        rail_dir = rail2.direction
        k = librail.args_to_key(signal_pos.x - rail_pos.x, signal_pos.y - rail_pos.y, signal_dir)
        t = signal_data[k]
        hit = t and rail2
    end
    return t, hit, rail_pos, rail_dir
end

local Rail = {}

function Rail.get_connected_rails(rail, rail_direction)
    local get_rail = rail.get_connected_rail
    local rails, crs = {}, 0
    local tmp, chiral
    for _, con_dir in pairs(rcd) do
        tmp = get_rail{
            rail_direction = rail_direction,
            rail_connection_direction = con_dir
        }
        if tmp then
            crs = crs + 1
            chiral = chiral_directions[get_rail_data(rail).chirality == get_rail_data(tmp).chirality][rail_direction]
            rails[crs] = {tmp, chiral, con_dir}
        end
    end
    return rails, crs
end

function Rail.is_dead_end(rail, rail_direction)
    local get_rail = rail.get_connected_rail
    local tmp
    for _, con_dir in pairs(rcd) do
        tmp = get_rail{
            rail_direction = rail_direction,
            rail_connection_direction = con_dir
        }
        if tmp then
            return false
        end
    end
    return rail_direction
end

--walks in rcd.straight direction, until limit is reached or a curved rail or dead end
local _straight_only = {
    [rd.front] = {rail_direction = rd.front, rail_connection_direction = rcd.straight},
    [rd.back] = {rail_direction = rd.back, rail_connection_direction = rcd.straight}
}
local function get_starting_rail(rail, rail_direction, limit)
    limit = limit or 20
    local start_rail
    local test, prev = rail, rail
    local rail_data = get_rail_data(rail)
    local next_data
    local chiral = rail_direction

    local c = 1

    while (test and c <= limit) do
        --test = prev.get_connected_rail{rail_direction = chiral, rail_connection_direction = rcd.straight}
        test = prev.get_connected_rail(_straight_only[chiral])
        if test then
            assert(test.type == "straight-rail", "That shouldn't be a curve")
            next_data = get_rail_data(test)
            chiral = chiral_directions[rail_data.chirality == next_data.chirality][chiral]
            rail_data = next_data
            prev = test
            assert(rail_data)
        end
        c = c + 1
        start_rail = test and test or start_rail
    end
    if not Rail.is_dead_end(prev, chiral) then
        game.print("Don't start before a curve")
        return
    end
    if not start_rail and prev == rail then
        return rail, rail_direction
    end
    return start_rail, chiral
end

local function get_rail_segment_entity(rail, direction, entrance, reverse_direction)
    local res
    if reverse_direction then
        res = rail.get_rail_segment_entity(direction, not entrance)
    else
        res = rail.get_rail_segment_entity(direction, entrance)
    end
    return (res and signal_types[res.type]) and res or nil
end

local function log_segment(segment)--luacheck: no unused
    local s, e = segment.seg_start, segment.seg_end
    local ret = segment.id .. "\tlength: " .. segment.length .. "\tneighbours: " .. (segment.neighbours and table_size(segment.neighbours) or "") ..
        "\n\t seg_start:\t" .. log_entity(s.rail, "rail " .. tostring(s.rail and s.rail.unit_number), true) .. "\tout_dir: " .. s.out_dir ..
        "\n\t seg_end:\t" .. log_entity(e.rail, "rail " .. tostring(e.rail and e.rail.unit_number), true) .. "\tout_dir: " .. e.out_dir
        if segment.signals and table_size(segment.signals) > 0 then
            ret = ret .. "\n\t\tsignals:"
            for i, signal in pairs(segment.signals) do
                ret = ret .. log_entity(signal.signal, " "..i, true) .. log_entity(signal.rail, " rail " .. tostring(signal.rail and signal.rail.unit_number), true) .. "\n\t\t\t"
            end
        end
        return ret
end

--returns connected rail, the direction to keep going "forwards" and the end of the segment
--5th param is the rcd used to get the rail
local function each_connected_rail(rail, rail_direction)
    local t = librail.cr_straight_first[rail_direction]
    --local t = rcd_straight_first
    local i, n = 0, #t
    local connected
    local get_rail = rail.get_connected_rail
    local rail_chiral = get_rail_data(rail).chirality
    local function iterator()
        while i < n do
            i = i + 1
            connected = get_rail(t[i])
            if connected then
                local chiral = chiral_directions[rail_chiral == get_rail_data(connected).chirality][rail_direction]
                local seg_end, se_dir = connected.get_rail_segment_end(chiral)--jump_to_end(connected, chiral)
                return  connected, chiral, seg_end, se_dir, t[i].rail_connection_direction
            end
        end
    end
    return iterator
end

local function get_closest_signal(dead_end, de_dir, reverse_dir)
    local signal = false
    local best = math.huge
    local visited = {[dead_end.unit_number] = true}
    local function _recurse(seg_start, s_dir, start_len)
        local distance
        local id

        for rail, rail_dir, seg_end, se_dir in each_connected_rail(seg_start, s_dir) do
            id = rail.unit_number
            if visited[id] then
                game.print("Cycle detected")
                break
            else
                visited[id] = true
            end

            local seg_len = rail.get_rail_segment_length()
            distance = start_len
            local first_signal = get_rail_segment_entity(rail, opposite_rail_direction[rail_dir], false, reverse_dir)
            local second_signal, s_data

            if first_signal then
                s_data = get_signal_data2(first_signal, rail)
                local l = get_rail_data(rail).length
                --local _distance = reverse_dir and distance + s_data.signal.stops or distance + l - s_data.signal.starts
                local _distance = signal_distances(distance, s_data.signal, l, not reverse_dir)
                -- log2(distance, "start_len")
                -- log2(_distance, "first signal")
                -- log2(s_data.signal)
                render.mark_signal(first_signal, "de", colors.green, nil, nil, round(_distance, 1))
                if _distance < best then
                    best = _distance
                    signal = first_signal
                    goto continue
                end
            else
                distance = distance + seg_len
                if distance >= best then
                    render.mark_entity_text(seg_end, "early", nil, {top = true})
                    goto continue
                end
                second_signal = get_rail_segment_entity(seg_end, se_dir, true, reverse_dir)
                if second_signal then
                    -- log2(distance, "start_len")
                    render.mark_signal(second_signal, "en", colors.red,  nil, nil, round(distance, 1))
                    s_data = get_signal_data2(second_signal, seg_end)

                    local _distance = reverse_dir and distance - seg_len + s_data.signal.starts or distance - seg_len + s_data.signal.stops
                    -- log2(_distance, "second signal")
                    -- log2(s_data.signal)
                    if _distance < best then
                        best = _distance
                        signal = second_signal
                        goto continue
                    end
                end
            end
            _recurse(seg_end, se_dir, distance)
            ::continue::
        end
    end

    render.on(true)

    local seg_starta, s_dira = dead_end.get_rail_segment_end(opposite_rail_direction[de_dir])--jump_to_end(dead_end, opposite_rail_direction[de_dir])

    local seg_length = dead_end.get_rail_segment_length()
    local de_signal = get_rail_segment_entity(dead_end, de_dir, false, reverse_dir)
    local rail_l = get_rail_data(dead_end).length
    local s_data, _
    if de_signal then
        --! fix distance
        s_data = get_signal_data2(de_signal, dead_end)
        if s_data then
            -- log("de_signal")
            signal = de_signal
            -- log2(s_data.signal)
            -- best = reverse_dir and (s_data.signal.stops) or (rail_l - s_data.signal.starts)
            _, best = signal_distances(0, s_data.signal, rail_l, reverse_dir)
            render.mark_signal(de_signal, "de1", colors.green, nil, {alt = true}, best)
        end
    else
        --that's the most likely case i guess
        local seg_start_signal = get_rail_segment_entity(seg_starta, s_dira, true, reverse_dir)
        if seg_start_signal then
            --! fix distance
            s_data = get_signal_data2(seg_start_signal, seg_starta)
            if s_data then
                -- log("seg_start_signal")
                signal = seg_start_signal
                -- log2(s_data.signal)

                best = reverse_dir and (seg_length - (rail_l - s_data.signal.stops)) or (seg_length - rail_l) + (rail_l - s_data.signal.starts)
                render.mark_signal(seg_start_signal, "en1", colors.red, nil, nil, best)
            end
        end
    end
    if not signal then
        _recurse(seg_starta, s_dira,  seg_length)
    end

    --render.mark_signal(signal, "C", colors.blue, nil, nil, best)
    render.restore()
    --?adjust length according to signal data
    return signal, best
end

local function get_closest_pole(rail, pole_name)
    local reach = game.entity_prototypes[pole_name].max_wire_distance
    local min_distance, pole = 900, nil
    --? should be the position of the pole, not the rail?
    local pos = lib.diagonal_to_real_pos(rail)
    for _, p in pairs(rail.surface.find_entities_filtered { area = Position.expand_to_area(pos, reach), name = pole_name }) do
        local dist = Position.distance(pos, p.position)
        if min_distance > dist then
            pole = p
            min_distance = dist
        end
    end
    return pole, min_distance, reach
end

local function get_rail_direction_from_loco(entity, rail, is_front_mover)
    local rail_direction = is_front_mover and entity.train.rail_direction_from_front_rail or entity.train.rail_direction_from_back_rail
    local data = get_rail_data(rail)
    if rail.type == "curved-rail" then
        local loco_o = entity.orientation * 8
        local calc_orientation = data.rd_to_travel[rail_direction]
        local diff = math.abs(loco_o - calc_orientation)
        diff = diff > 7 and diff - 7 or diff
        -- log2(calc_orientation, "Calc")
        -- log2(loco_o, "loco_o")
        -- log2(diff, "Diff")
        if diff > 0.81 then
            return
        end
    end
    local travel_direction = data.rd_to_travel[rail_direction]
    return rail_direction, travel_direction
end

--[[
To activate FARL we need:
    Absolutely:
    - The last rail of a (straight) segment:
        - Get the rail under the locomotive, walk straight in the direction until the end (or to a branch?)
        - check for signals along the way? rail_segment_entity/end ?
    Optional:
    - The closest signal in travel direction and the distance to the last rail
    - The closest pole (or the pole maybe not so close pole that matches the position relative to the rail bp)
--]]

local function get_startup_data(entity, pdata)
    local train = entity.train

    local carriages = train.carriages
    local in_front_mover = carriages[1] == entity
    if not in_front_mover and carriages[#carriages] ~= entity then
    --if not ((in_front_mover and carriages[1] or carriages[#carriages]) == entity) then
        return false, "Not in first or last locomotive, or facing the wrong direction"
    end

    --log("Front_mover: " .. tostring(in_front_mover))
    local front = in_front_mover and train.front_rail or train.back_rail
    --log("front rail: " .. front.type .. " " .. front.direction)

    local rail_direction, travel_direction = get_rail_direction_from_loco(entity, front, in_front_mover)
    -- log2(find_key(rd, rail_direction), "Calc")
    -- log2(find_key(rd, entity.train.rail_direction_from_front_rail), "api")
    if not rail_direction then
        return false, "Too far from end of curve"
    end

    local dead_end, de_direction = get_starting_rail(front, rail_direction)

    if not dead_end then
        return false, "No starting rail"
    end
    --log2(find_key(rd, de_direction), "de_dir")
    --log(log_entity(dead_end, "Starting rail", true))
    local signal, distance = get_closest_signal(dead_end, de_direction, false)

    local pole, pole_dist, reach
    if pdata then
        local bp_data = pdata.bp_data[travel_direction % 2 == 1]
        if bp_data.main_pole then
            pole, pole_dist, reach = get_closest_pole(dead_end, bp_data.main_pole.name)
        end
    end

    render.on(true)
    render.mark_rail(dead_end, colors.green, "S", true)
    --render.mark_entity_text(dead_end, tostring(distance))
    --render.mark_signal(signal, "C", colors.green, nil, nil, distance)
    render.restore()
    return dead_end, signal, pole, distance, travel_direction, de_direction, pole_dist, reach
end

local function find_parallel_rails(farl, data)
    local c, block
    local pos = farl.last_rail.position
    local find_entity = farl.surface.find_entities_filtered
    local create_entity = farl.surface.create_entity
    local create = {force = farl.force, position = {x=0,y=0}, direction = 0, name = farl.rail_name["straight-rail"], limit = 1}
    local same_dir = farl.last_rail.direction == data.main_rail.direction
    local dead_end_dir, travel_rd, travel_direction = farl.last_rail.direction, farl.travel_rd, farl.travel_direction
    for li, lane in pairs(data.lanes) do
        if not lane.main then
            block = farl.last_curve_input * lane.block_left
            create.position = Position.add(pos, lane.position)
            create.direction = same_dir and lane.direction or (lane.direction + 4) % 8
            c = find_entity(create)
            if c[1] then
                farl.last_lanes[li] = {rail = c[1]}
                render.mark_rail(c[1], nil, "s", true, {alt = true})
            else
                c = create_rail(create_entity, create, farl.surface)
                if c then
                    farl.last_lanes[li] = {rail = c}
                    render.mark_entity(c, nil, tostring(block))
                else
                    farl.last_lanes[li] = {}
                end
            end
            if farl.last_lanes[li].rail then
                local de_dir = dead_end_dir == farl.last_lanes[li].rail.direction and travel_rd or opposite_rail_direction[travel_rd]
                if lane.travel_dir then
                    local _signal, dist = get_closest_signal(farl.last_lanes[li].rail, de_dir, travel_direction ~= lane.travel_dir)
                    render.mark_entity_text(farl.last_lanes[li].rail, tostring(dist))
                    farl.last_lanes[li].dist = dist
                    farl.last_lanes[li].signal = _signal
                end
            end
        end
    end
end

local function find_parallel_curves(farl)
    local c
    local find_entity = farl.surface.find_entities_filtered
    local create_entity = farl.surface.create_entity
    local create = {force = farl.force, position = {x=0,y=0}, direction = 0, name = farl.rail_name["curved-rail"], limit = 1}

    local old_travel = (get_rail_data(farl.last_rail).rd_to_travel[opposite_rail_direction[farl.travel_rd]] + 4) % 8
    local curve_input = (farl.travel_direction + 1) % 8 == old_travel and 1 or -1
    local new_bp_data = old_travel % 2 == 0 and farl.bp_data[old_travel] or farl.bp_data[farl.travel_direction]
    local left = old_travel % 2 == 0 and (old_travel + 10) % 8 or (farl.travel_direction + 10) % 8
    local dead_end_dir, travel_rd, travel_direction = farl.last_rail.direction, farl.travel_rd, farl.travel_direction
    for li, lane in pairs(new_bp_data.lanes) do
        if not lane.main then
            create.position = Position.translate(farl.last_rail.position, lane.distance, left)
            if old_travel % 2 == 0 then
                create.position = Position.translate(create.position, curve_input * lane.block_left, (left + 2) % 8)
            else
                create.position = Position.translate(create.position, curve_input * lane.block_left, (left + 6) % 8)
            end
            create.direction = lane.direction
            log2(create.position, "curve")
            c = find_entity(create)
            if c[1] then
                farl.last_lanes[li] = {rail = c[1]}
                render.mark_rail(c[1], nil, "s", true, {alt = true})
            else
                c = create_rail(create_entity, create, farl.surface)
                if c then
                    farl.last_lanes[li] = {rail = c}
                    render.mark_entity(c, nil, "c")
                else
                    farl.last_lanes[li] = {}
                end
            end
            if farl.last_lanes[li].rail then
                local de_dir = dead_end_dir == farl.last_lanes[li].rail.direction and travel_rd or opposite_rail_direction[travel_rd]
                if lane.travel_dir then
                    local _signal, dist = get_closest_signal(farl.last_lanes[li].rail, de_dir, travel_direction ~= lane.travel_dir)
                    farl.last_lanes[li].dist = dist
                    farl.last_lanes[li].signal = _signal
                end
            end
        end
    end
    return curve_input
end

local function on_player_driving_changed_state(event)
    --profiler.Start()
    local player = game.get_player(event.player_index)
    local pdata = global._pdata[event.player_index]
    if player.vehicle then
        local loco = player.vehicle
        render.player_index = {event.player_index}
        render.surface = player.surface
        if loco and loco.name == "farl" then
            local dead_end, signal, pole, distance, travel_direction, travel_rd, pole_dist, reach = get_startup_data(loco, pdata)
            if not dead_end then
                game.print(signal)
                return
            end
            game.write_file("bp_data2.lua", serpent.block(pdata.bp_data2, {name = "bp_data2"}))
            local bp_data = pdata.bp_data2[travel_direction]
            local is_diagonal = travel_direction % 2 == 1
            pdata.train_id = loco.train.id
            pdata.farl = {
                last_rail = dead_end,
                --TODO find the last curve and input (up to max lag away)
                last_curve_dist = 100,
                last_curve_input = 0,
                last_lanes = {},
                rail_name = {
                    ["straight-rail"] = "straight-rail",
                    ["curved-rail"] = "curved-rail"
                },
                pole = pole,
                pole_reach = reach,
                pole_distance = 0,
                pole_candidate = bp_data.main_pole and {name = bp_data.main_pole.name, position = {x = 0, y = 0}, direction = bp_data.main_pole.direction, force = loco.force},
                signal = signal,
                dist = distance,
                travel_direction = travel_direction,
                travel_rd = travel_rd,
                player = player,
                driver = player,
                loco = loco,
                force = loco.force,
                surface = loco.surface,
                bp_data = pdata.bp_data2}
            global.active[loco.train.id] = pdata.farl
            local farl = pdata.farl
            render.on(true)
            rendering.clear("FARL")

            if dead_end.type ~= "curved-rail" then
                find_parallel_rails(farl, bp_data)
            else
                farl.last_curve_input = find_parallel_curves(farl)
                farl.last_curve_dist = 0
            end

            render.mark_rail(dead_end, colors.green, "S", true)
            render.mark_entity_text(dead_end, tostring(distance))
            --render.mark_signal(signal, "C", colors.green, nil, {alt = true}, distance)
            render.mark_entity(pole, colors.green, "P")
            render.mark_entity_text(pole, pole_dist)
            local data = pdata.bp_data[is_diagonal]
            if data then
                pdata.farl.line = render.draw_line(loco, loco, colors.red, nil, nil, {from_offset = Position.rotate({x = -1, y = -6}, travel_direction * 45), to_offset = Position.rotate({x = 1, y = -6}, travel_direction * 45)})
                script.on_event(defines.events.on_tick, on_tick)
                log("Registered")
            end
            render.restore()
        end
    else
        if pdata.train_id then
            global.active[pdata.train_id] = nil
            if table_size(global.active) == 0 then
                script.on_event(defines.events.on_tick, nil)
                log("Unregistered")
            end
        end
        rendering.clear("FARL")
    end
    log2(calls, "Rail data calls")
    log2(hits, "Hits")
    profiler.Stop()
end

local function on_pre_player_removed()

end

local function script_raised_destroy()

end

local function on_player_alt_selected_area(event)
    if not (event.item == "farl_selection_tool") then return end
    local player = game.get_player(event.player_index)
    global.tests_expected = global.tests_expected or {}
    if not player.vehicle then
        if not global.tests_confirm then
            game.print("Get in a train to set/clear expected results")
            global.tests_confirm = true
            return
        else
            game.print("Clearing all expected results")
            global.tests_confirm = nil
            global.tests_expected = {}
            return
        end
    end
    local loco = player.vehicle
    local id = loco.unit_number
    local tc = global.tests_expected[id] or {}
    local loco_str = "{name = %q, position = {x = %s, y = %s}, orientation = %s, force = %q}"
    local pos, d = loco.position, loco.orientation
    tc.loco = string.format(loco_str, loco.name, pos.x, pos.y, round(d, 4), loco.force.name)
    if table_size(event.entities) == 0 then
        tc.rail = nil
        tc.signal = nil
        global.tests_expected[id] = tc
        player.print("Cleared expected results")
        return
    end

    for _, ent in pairs(event.entities) do
        pos, d = ent.position, ent.direction or 0
        if signal_types[ent.type] then
            tc.signal =  string.format("%d", lib.position_hash(pos.x, pos.y, d))
            player.print("Selected expected signal")
        end
        if rail_types[ent.type] then
            tc.rail = string.format("%d", lib.position_hash(pos.x, pos.y, d))
            player.print("Selected expected rail")
        end
    end
    global.tests_expected[id] = tc
end
script.on_event(defines.events.on_player_alt_selected_area, on_player_alt_selected_area)

local function on_player_selected_area(event)
    if not (event.item == "farl_selection_tool" and table_size(event.entities) > 0) then return end
    local player = game.get_player(event.player_index)
    local pos, c, ec
    local entities_c = {0, 0, 0, 0}
    global.tests_expected = global.tests_expected or {}
    global.tests_created = global.tests_created or 1
    local def = {
        rails = 1,
        signals = 2,
        rolling_stock = 3,
        other = 4
    }
    local def2 ={}
    for k, v in pairs(def) do
        def2[v] = k
    end

    local entities = {{},{},{},{}}
    local format = string.format

    local function interp(s, tab)
        return (s:gsub('($%b{})', function(w) return tab[w:sub(3, -2)] or w end))
    end
    --http://lua-users.org/wiki/StringInterpolation
    --getmetatable("").__mod = interp
    local table_name = "startup"
    local src = [[
${tbl}[${i}] = {
    name = "Test${i}",
    test_type = "",
    to_create = {
        rails = {
${rails}
        },
        signals = {
${signals}
        }
    },
    cases = {
${cases}
    }
}
]]

    local returns = {', false', ', false'}
    local create_entity = "            [%d] = {name = %q, position = {x = %s, y = %s}, direction = %d, force = %q},\n"
    local inf = math.huge
    local r_min_x, r_max_x = inf, -inf
    local r_min_y, r_max_y = inf, -inf
    local bottom
    local min_x, max_y = inf, - inf

    --local cases = {}
    for _, entity in pairs(event.entities) do
        c = (rail_types[entity.type] and def.rails) or (signal_types[entity.type] and def.signals) or (rolling_stock_types[entity.type] and def.rolling_stock) or def.other
        ec = entities_c[c] + 1
        pos = {x = entity.position.x, y = entity.position.y}
        table.insert(entities[c], {lib.position_hash(pos.x, pos.y, entity.direction or 0), entity.name, pos.x, pos.y, entity.direction or 0, entity.force.name})
        entities_c[c] = ec
        if c == def.rails then
            if entity.type == "straight-rail" then
                if min_x > pos.x and max_y < pos.y then
                    bottom = entity
                    min_x = pos.x
                    max_y = pos.y
                end
            end
            r_min_x = pos.x < r_min_x and pos.x or r_min_x
            r_max_x = pos.x > r_max_x and pos.x or r_max_x
            r_min_y = pos.y < r_min_y and pos.y or r_min_y
            r_max_y = pos.y > r_max_y and pos.y or r_max_y
        end
        -- if c == def.rails and entity == global.tests_expected.rail then
        --     cases[2] = format("        rail = %d", ec)
        -- end
        -- if c == def.signals and entity == global.tests_expected.signal then
        --     cases[3] = format("        signal = %d", ec)
        -- end
    end

    --cases[1] = cases[1] or (entities[def.rolling_stock][1] and format("loco = ${tbl}[${i}].created_entities.%s[%d]", def2[def.rolling_stock], 1))
    -- if not cases[1] then
    --     game.print("No loco to test.")
    --     return
    -- end
    -- if not cases[2] then
    --     game.print("No rail, assuming false test")
    --     cases[2] = "        rail = false"
    --     cases[3] = "        signal = 'some error'"
    -- end
    -- if not cases[2] and not cases[3] then
    --     game.print("No signal, assuming false test")
    --     cases[3] = "        signal = false"
    -- end
    --print(serpent.block(cases))
    local cases = {}
    local case_str = "{loco = %s, rail = %s, signal = %s}"
    local cc = 1
    for _, case in pairs(global.tests_expected) do
        cases[cc] = {
            [1] = case.loco,
            [2] = case.rail,
            [3] = case.signal
        }

        if not case.rail then
            game.print("No rail, assuming false test")
            cases[cc][2] = "false"
            cases[cc][3] = "'some error'"
        end
        if case.rail and not case.signal then
            game.print("No signal")
            cases[cc][3] = "false"
        end
        cases[cc] = format(case_str, case.loco, cases[cc][2], cases[cc][3])
        cc = cc + 1
    end
    cases = interp(table.concat(cases, ",\n"), {i = global.tests_created, tbl = table_name})
    local offset = {x =(min_x or 1) - 1, y = (max_y or 1) - 1}

    print(serpent.line(offset))

    for i, ents in pairs(entities) do
        for j, ent in pairs(ents) do
            -- ent[4] = ent[4] - offset.x
            -- ent[5] = ent[5] - offset.y
            entities[i][j] = format(create_entity, table.unpack(ent))
        end
    end
    rendering.clear("FARL")
    render.on(true)
    render.mark_entity(bottom, nil, "B")
    -- render.surface = player.surface
    -- render.draw_rectangle({x=r_min_x, y = r_min_y}, {x=r_max_x, y = r_max_y}, nil, nil, {ttl = 600})
    render.restore()

    for i, ents in pairs(entities) do
        entities[i] = table.concat(ents)
    end
    returns = table.concat(returns)
    src = interp(src, {i = global.tests_created, tbl = table_name,
        def_list = table.concat(def2, ", "),
        rails = entities[def.rails],
        signals = entities[def.signals],
        trains = entities[def.rolling_stock],
        returns = returns,
        cases = cases}
        )

    local gui = player.gui.left.farl_code
    local box
    if not (gui and gui.valid) then
        gui = player.gui.left.add{
            name = "farl_code",
            type = "frame",
            direction = "vertical"
        }
        box = gui.add{
            name = "code_text",
            type = "text-box",
            text = src
        }
        --box.read_only = true
        box.style.height = player.display_resolution.height * 0.4 / player.display_scale
        box.style.width = player.display_resolution.width * 0.4 / player.display_scale
        local f = gui.add{
            type = "flow",
            direction = "horizontal"
        }
        f.add{
            name = "farl_code_close",
            type = "button",
            caption = "Close"
        }
        f.add{
            type = "flow",
            direction = "horizontal"
        }.style.horizontally_stretchable = true
        f.add{
            name = "farl_test_index",
            type = "textfield",
            text = global.tests_created
        }
        f.add{
            name = "farl_code_ok",
            type = "button",
            caption = "Ok"
        }
    else
        player.gui.left.farl_code.code_text.text = src
    end
    --box.select_all()
    --box.focus()
end

script.on_init(on_init)
script.on_load(on_load)
script.on_configuration_changed(on_configuration_changed)
script.on_event(defines.events.on_player_created, on_player_created)
script.on_event(defines.events.on_pre_player_removed, on_pre_player_removed)
-- script.on_event(defines.events.on_player_toggled_map_editor, function(event)
--     log(find_key(defines.controllers, game.get_player(event.player_index).controller_type))
-- end)

script.on_event(defines.events.on_player_selected_area, on_player_selected_area)

script.on_event(defines.events.on_gui_click, on_gui_click)
script.on_event(defines.events.on_gui_checked_state_changed, on_gui_checked_state_changed)

script.on_event(defines.events.on_pre_player_mined_item, on_preplayer_mined_item)
script.on_event(defines.events.on_entity_died, on_entity_died)
script.on_event(defines.events.on_marked_for_deconstruction, on_marked_for_deconstruction)
script.on_event(defines.events.script_raised_destroy, script_raised_destroy)

script.on_event(defines.events.on_player_driving_changed_state, on_player_driving_changed_state)

local function farl_test(event)
    on_init()
    lib.saveVar(librail.rail_data, "rail_data")
    local player = game.get_player(event.player_index)
    if player.character then
        player.character_reach_distance_bonus = 100
        player.character_build_distance_bonus = 100
    end
    render.player_index = {event.player_index}
    render.surface = player.surface
    if player.cursor_stack.valid_for_read then
        local selected = player.cursor_stack
        if selected.type == "blueprint" then
            local ents, bp_data, chain_signal, is_diagonal = Blueprint.rotate(selected, signal_types)
            if not ents then
                game.print("No chain signal")
                return
            end

            local main_rail = Blueprint.parse(bp_data, chain_signal, is_diagonal, ents, player)

            render.on(true)
            rendering.clear("FARL")
            local box = bp_data.bounding_box
            render.draw_rectangle(player.character, player.character, colors.green, false, {left_top_offset = box.left_top, right_bottom_offset = box.right_bottom})
            log2(box, "bounding box")

            if is_diagonal then
                player.teleport({x = math.floor(player.position.x) + 0.5, y = math.floor(player.position.y) + 0.5})
            else
                player.teleport({x = math.floor(player.position.x), y = math.floor(player.position.y)})
            end

            --split bounding box into #lanes parts
            for li, lane in pairs(bp_data.lanes) do
                log2(lane.distance, "lane " .. li)
                local dist = is_diagonal and lane.distance * 2 or lane.distance
                render.draw_circle(player.character, nil, nil, true, {target_offset = {dist, 0}})
                lane.bb = {left_top = {x = box.left_top.x, y = box.left_top.y}, right_bottom = {x = box.right_bottom.x, y = box.right_bottom.y}}
                if li - 1 > 0 then
                    lane.bb.left_top.x = bp_data.lanes[li - 1].bb.right_bottom.x
                end
                if li+1 <= #bp_data.lanes then
                    local dist2 = is_diagonal and bp_data.lanes[li+1].distance * 2 or bp_data.lanes[li+1].distance
                    local tmp = (math.abs(dist) + dist2)  / 2
                    if dist < 0 then
                        lane.bb.right_bottom.x = dist + tmp
                    elseif dist == 0 then
                        if li - 1 > 0 then
                            lane.bb.left_top.x = bp_data.lanes[li - 1].bb.right_bottom.x
                        end
                        if li + 1 <= #bp_data.lanes then
                            lane.bb.right_bottom.x = tmp
                        end
                    else
                        lane.bb.left_top.x = dist + tmp
                    end
                    render.draw_circle(player.character, nil, colors.green, false, {target_offset = {dist + tmp, 0}})
                end
                log2(lane.bb, "lane bb")
                render.draw_rectangle(player.character, player.character, colors.red, nil, {left_top_offset = lane.bb.left_top, right_bottom_offset = lane.bb.right_bottom})
            end

            --All important entities (rail, main pole) should exist now
            --One final pass to calculate the necessary offsets and bounding box
            --offsets relative to rail for walls, for other rails technically only left/right distance is necessary?
            --offsets relative to pole: signals, anything that isn't a rail or a wall?

            local pdata = global._pdata[player.index]
            pdata.bp_data[is_diagonal] = bp_data
            local data = pdata.bp_data
            log("")
            local cblock_left, cblock_right = 0, 0
            local dcblock_left, dcblock_right = 0, 0
            --local max_lag_s, max_lag_d = 0, 0
            local left_lane, right_lane
            local left_lane_d, right_lane_d
            local pole, pole_d
            if data[false] and data[true] and #data[true].lanes == #data[false].lanes then
                pole = data[false].main_pole
                pole_d = data[true].main_pole
                --sorted from left to right (left < 0 distance)
                for i, rail in pairs(data[false].lanes) do
                    --if not rail.main then
                        local rail_d = data[true].lanes[i]
                        local Sd = rail.track_distance
                        local Dd = rail_d.track_distance
                        log2(Sd, "Sd")
                        log2(Dd, "Dd")
                        local n = Sd - Dd--for positive n: n*2 is the amount of rails needed to catchup
                        log2(n, "lag_s")--lag for straight -> diagonal (+/- are for right turns, for left invert it)
                        local d = -Dd - 2 * n
                        log2(d, "lag_d")--lag for diagonal -> straight (+/- are for right turns, for left invert it)
                        rail.lag_s = n
                        rail.lag_d = d
                        rail_d.lag_s = n
                        rail_d.lag_d = d

                        -- max_lag_s = math.abs(n) > max_lag_s and math.abs(n) or max_lag_s
                        -- max_lag_d = math.abs(d) > max_lag_d and math.abs(d) or max_lag_d
                        if pole then
                            if not left_lane then
                                -- log2(rail.distance < pole.distance, "ll")
                                left_lane = rail.distance < pole.distance and i
                            end
                            if not right_lane then
                                right_lane = rail.distance > pole.distance and i
                            end
                        end
                        if pole_d then
                            --if not left_lane_d then
                                log2(rail_d.distance < pole_d.distance, "ll d" .. i)
                                left_lane_d = rail_d.distance < pole_d.distance and i
                            --end
                            if not right_lane_d then
                                log2(rail_d.distance > pole_d.distance, "rl d" .. i)
                                right_lane_d = rail_d.distance > pole_d.distance and i
                            end
                        end

                        rail.position.x = Sd * 2
                        rail.position.y = main_rail.position.y + math.abs(2 * n)
                        --TODO make sure this works correct for bps with largely different distances
                        rail.block_left = 2 * rail.lag_s
                        cblock_left = cblock_left > rail.block_left and cblock_left or rail.block_left
                        cblock_right = cblock_right > - rail.block_left and cblock_right or - rail.block_left

                        rail_d.block_left = 2 * rail_d.lag_d
                        dcblock_left = dcblock_left > rail_d.block_left and dcblock_left or rail_d.block_left
                        dcblock_right = dcblock_right > - rail_d.block_left and dcblock_right or - rail_d.block_left

                        if rail.signal then
                            rail.signal.position.y = rail.signal.position.y + math.abs(2 * n)
                        end

                        rail_d.position = Position.translate({x = 0, y = 0}, Dd, dir.southeast)
                        if math.abs(Dd) % 2 == 1 then
                            rail_d.direction = (rail_d.direction + 4) % 8
                        end
                        rail_d.position = Position.translate(rail_d.position, math.abs(d), dir.southwest)
                        if math.abs(d) % 2 == 1 then
                            rail_d.direction = (rail_d.direction + 4) % 8
                        end

                        if rail_d.signal then
                            local r_data = librail.rail_data[rail_d.type][rail_d.direction]
                            local _rd = r_data.travel_to_rd[rail_d.travel_dir]
                            local pos = r_data.signals[_rd][1]
                            rail_d.signal.position = Position.add(rail_d.position, pos)
                        end
                    --end
                end
                data[false].curve_block = {[-1] = cblock_right, [1] = cblock_left}
                data[true].curve_block = {[-1] = dcblock_right, [1] = dcblock_left}
                -- data[false].max_lag = max_lag_s
                -- data[true].max_lag = max_lag_d

                if pole and pole_d then
                    local dist_l = left_lane and math.abs(pole.distance - data[false].lanes[left_lane].distance) or math.huge
                    local dist_r = right_lane and math.abs(pole.distance - data[false].lanes[right_lane].distance) or math.huge

                    if dist_l < dist_r then
                        pole.lane = left_lane
                    elseif dist_l > dist_r then
                        pole.lane = right_lane
                    elseif dist_l == dist_r then
                        --choose the NOT main lane
                        pole.lane = (left_lane and data[false].lanes[left_lane].main) and right_lane or left_lane or right_lane
                    end

                    dist_l = left_lane_d and math.abs(pole_d.distance - data[true].lanes[left_lane_d].distance) or math.huge
                    dist_r = right_lane_d and math.abs(pole_d.distance - data[true].lanes[right_lane_d].distance) or math.huge

                    if dist_l < dist_r then
                        pole_d.lane = left_lane_d
                    elseif dist_l > dist_r then
                        pole_d.lane = right_lane_d
                    elseif dist_l == dist_r then
                        --choose the NOT main lane
                        pole_d.lane = (left_lane_d and data[true].lanes[left_lane_d].main) and right_lane_d or left_lane_d or right_lane_d
                    end

                    log2(pole.distance, "main pole")
                    log2(pole_d.distance, "main pole d")
                end

                local both_poles = pole and pole_d
                if both_poles then
                    --adjust for medium/big poles (1x1/2x2 poles)
                    local correct = round(pole.position.y, 0) - pole.position.y
                    pole.position = Position.translate(data[false].main_rail.position, correct, dir.south)

                    pole.position = Position.translate(pole.position, pole.distance, dir.east)

                    local lag = math.abs(data[false].lanes[pole.lane].lag_s) * 2
                    pole.position = Position.translate(pole.position, lag, dir.south)
                    pole.real_pos = pole.position

                    if data[true].main_rail.direction == dir.northwest then
                        pole_d.position = Position.translate(data[true].main_rail.position, 1, dir.west)
                    else
                        pole_d.position = Position.translate(data[true].main_rail.position, 1, dir.south)
                    end
                    pole_d.position = Position.translate(pole_d.position, pole_d.distance, dir.southeast)

                    lag = math.abs(data[true].lanes[pole_d.lane].lag_d)
                    pole_d.position = Position.translate(pole_d.position, lag, dir.southwest)

                    pole_d.real_pos = Position.subtract(pole_d.position, lib._diagonal_data[data[true].main_rail.direction])
                end

                --create tables for the remaining directions, so i don't have to do all the calculations over and over again
                data = {[0] = pdata.bp_data[false], [1] = pdata.bp_data[true]}
                local tmp, deg
                for i = 3, 7, 2 do
                    data[i] = util.table.deepcopy(pdata.bp_data[true])
                    tmp = data[i]
                    tmp.bounding_box = lib.rotate_bounding_box(tmp.bounding_box, i - 1)
                    tmp.bb_l = lib.rotate_bounding_box(tmp.bb_l, i - 1)
                    tmp.bb_r = lib.rotate_bounding_box(tmp.bb_r, i - 1)
                    tmp.bounding_box.h = data[1].bounding_box.h
                    deg = (i - 1) * 45
                    for _, lane in pairs(tmp.lanes) do
                        lane.position = Position.rotate(lane.position, deg)
                        lane.travel_dir = lane.travel_dir and (lane.travel_dir + i - 1) % 8 or nil
                        lane.direction = (lane.direction + i - 1) % 8
                        if lane.signal then
                            lane.signal.direction = (lane.signal.direction + i - 1) % 8
                            lane.signal.position = Position.rotate(lane.signal.position, deg)
                        end
                    end
                    if both_poles then
                        data[i].main_pole.position = Position.rotate(data[i].main_pole.position, deg)
                        data[i].main_pole.real_pos = Position.rotate(data[i].main_pole.real_pos, deg)
                    end
                end
                for i = 2, 6, 2 do
                    data[i] = util.table.deepcopy(pdata.bp_data[false])
                    tmp = data[i]
                    tmp.bounding_box = lib.rotate_bounding_box(tmp.bounding_box, i)
                    tmp.bb_l = lib.rotate_bounding_box(tmp.bb_l, i)
                    tmp.bb_r = lib.rotate_bounding_box(tmp.bb_r, i)
                    tmp.bounding_box.h = data[0].bounding_box.h
                    deg = i * 45
                    for _, lane in pairs(tmp.lanes) do
                        lane.position = Position.rotate(lane.position, deg)
                        lane.travel_dir = lane.travel_dir and (lane.travel_dir + i) % 8 or nil
                        lane.direction = (lane.direction + i) % 4
                        if lane.signal then
                            lane.signal.direction = (lane.signal.direction + i) % 8
                            lane.signal.position = Position.rotate(lane.signal.position, deg)
                        end
                    end
                    if both_poles then
                        data[i].main_pole.position = Position.rotate(data[i].main_pole.position, deg)
                        data[i].main_pole.real_pos = Position.rotate(data[i].main_pole.real_pos, deg)
                    end
                end
                pdata.bp_data2 = data

                for i = 0, 7 do
                    local c_pos
                    local right = (i + 2) % 8
                    -- log2(i, "travel dir")
                    local bb = data[i].bounding_box
                    local area
                    local mrail = data[i].main_rail
                    local de_pos = {x = 0, y = 0}

                    data[i].curves = {[1] = {}, [-1] = {}}
                    data[i].clear_area = {[1] = {}, [-1] = {}}
                    for input, j in pairs({[drd.right] = -1, [drd.left] = 1}) do
                        -- log2(j, "input")
                        local curve = get_next_rail(mrail, librail.rail_data["straight-rail"][mrail.direction].travel_to_rd[i], input)
                        if curve.type == "straight-rail" then
                            mrail = curve
                            --de_pos = lib.diagonal_to_real_pos(mrail)
                            curve = get_next_rail(mrail, librail.rail_data["straight-rail"][mrail.direction].travel_to_rd[i], input)
                        end
                        area = {left_top = Position.add(de_pos, bb.left_top), right_bottom = Position.add(de_pos, bb.right_bottom)}
                        --log2(curve, "curve")
                        local _area = librail.rail_data["curved-rail"][curve.direction].clear_area
                        local mv
                        local origin = {x = 0, y = 0}
                        for li, lane in pairs(data[i].lanes) do
                            c_pos = Position.translate({x = 0, y = 0}, lane.distance, right)
                            if i % 2 == 0 then
                                mv = j * lane.block_left
                                c_pos = Position.translate(c_pos, mv, (i + 4) % 8)
                                c_pos.foo = mv
                                if j == 1 and li == #data[i].lanes then
                                    c_pos.foo = -mv * 2
                                end
                            else
                                mv = j * ((data[(i+1) % 8].lanes[li].block_left) + lane.distance)
                                c_pos = Position.translate(c_pos, mv, i)
                                c_pos.foo = -j * data[i].lanes[li].lag_s
                            end
                            if li == 1 or li == #data[i].lanes then
                                --local which = (i % 2 == 0 ) and i or
                                local bb_d = li == 1 and data[i].bb_l or data[i].bb_r
                                if #data[i].lanes == 1 then
                                    bb_d = data[i].bounding_box
                                end
                                if i % 2 == 0 then
                                    c_pos.bb = Position.shift_area_center(bb_d, Position.translate(origin, lane.distance, right))
                                else
                                    c_pos.bb = Position.shift_area_center(bb_d, Position.translate(origin, 2 * lane.distance, (i + 1) % 8))
                                end

                                bb_d = li == 1 and data[(i + j*7) % 8].bb_l or data[(i + j*7) % 8].bb_r
                                if #data[i].lanes == 1 then
                                    bb_d = data[(i + j*7) % 8].bounding_box
                                end
                                local prev_distance = data[(i+1) % 8].lanes[li].distance
                                if i % 2 == 0 then
                                    if j == -1 then--right turn
                                        c_pos.bb2 = Position.shift_area_center(bb_d, Position.translate(origin, 2 * prev_distance, right))
                                    else--left turn
                                        c_pos.bb2 = Position.shift_area_center(bb_d, Position.translate(origin, 2 * prev_distance, i))
                                    end
                                else
                                    if j == -1 then--right turn
                                        c_pos.bb2 = Position.shift_area_center(bb_d, Position.translate(origin, prev_distance, (i + 3) % 8))
                                    else--left turn
                                        c_pos.bb2 = Position.shift_area_center(bb_d, Position.translate(origin, prev_distance, (i + 1) % 8))
                                    end
                                end
                            end
                            c_pos.entrance_pos = Position.add(c_pos, lib.diagonal_to_real_pos(get_rail_data(curve).exit_rails[(i + 4) % 8]))
                            c_pos.exit_pos = Position.add(c_pos, lib.diagonal_to_real_pos(get_rail_data(curve).exit_rails[(i + j * 7) % 8]))

                            data[i].curves[j][li] = c_pos
                            local _tmp = {left_top = Position.add(_area.left_top, c_pos), right_bottom = Position.add(_area.right_bottom, c_pos)}
                            Position.merge_area(area, _tmp)
                        end
                        data[i].clear_area[j] = area
                    end
                end

                game.write_file("bp_data2.lua", serpent.block(data, {name = "bp_data2"}))
            else
                game.print("Incomplete bp")
            end

            selected.set_blueprint_entities(ents)
            game.write_file("bp_data.lua", serpent.block(pdata.bp_data, {name = "bp_data"}))
            --game.write_file("reapplied.lua", serpent.block(selected.get_blueprint_entities()))
        end
    end

    if player.selected then
        local selected = player.selected
        local sel_type = player.selected.type
        rendering.clear("FARL")

        log("\n"..log_entity(selected, "Current"))
        if global.selected and global.selected.valid then
            local offset = Position.subtract(selected.position, global.selected.position)
            print2(log_entity(global.selected), "Prev")
            print2(offset, "Diff")
            --print2(Position.distance(selected.position, global.selected.position), "Dist")
            --print2(Position.distance(lib.diagonal_to_real_pos(selected), lib.diagonal_to_real_pos(global.selected))/math.sqrt(2), "real Dist")
        end
        global.selected = selected

        if sel_type == "locomotive" then
            local p = game.create_profiler()
            selected.set_driver(player)
            p.stop()
            log{"", p}
        elseif rail_types[sel_type] then
            local data = get_rail_data(selected).next_rails
            rendering.clear("FARL")
            render.on(true)
            for _, rdir in pairs(rd) do
                for rail, rail_dir, _, _, con in each_connected_rail(selected, rdir) do
                    local diff = Position.subtract(rail.position, selected.position)
                    --print(find_key(rcd, con) .. " " .. serpent.line(diff))
                    if not Position.equals(diff, data[rdir][con].position) then
                        game.print("Wrong position, rd: " .. find_key(rd, rdir))
                        game.print("E " .. serpent.line(data[rd.front][con].position))
                        game.print("R " .. serpent.line(diff))
                        render.mark_rail(rail, nil, rail_dir .. " " .. con)
                    end
                end
            end
            render.restore()

            log(log_entity(selected, "Selected"))
            log2(string.format("%d", lib.position_hash(selected.position.x, selected.position.y, selected.direction or 0)), "key")
        end
    elseif player.vehicle then
        player.vehicle.set_driver(nil)
    end
end
script.on_event("farl_debug_test", farl_test)
script.on_event({defines.events.on_built_entity, defines.events.on_robot_built_entity}, function(event)
    if event.created_entity.name == "farl" then
        event.created_entity.get_fuel_inventory().insert{name = "solid-fuel", count=2}
    end
end)

local function on_nth_tick(event)
    --print(serpent.line(event))
    local i = global.tests_current_test
    --test_runner.run(test_cases, get_startup_data)

    local test = test_cases[i]
    if not test then
        global.tests_current_test = nil
        global.tests_setup = nil
        global.tests_init = nil
        script.on_nth_tick(event.nth_tick, nil)
        return
    end
    if not global.tests_setup then
        print("---\t" .. test.name .. "\t---")
        print("Creating rails")
        test_runner.create_rails(test, game.get_surface(1))
        --test.create_rails(game.get_surface(1))
        global.tests_setup = 1
        rendering.clear("FARL")
        return
    else
        local j = global.tests_setup
        local case = test.cases[j]
        if case then
            if not global.tests_init then
                print("case " .. j)
                test_cases.init(test, j, game.get_surface(1))
                global.tests_init = true
                rendering.clear("FARL")
                return
            else
                if not test_runner.test_case(case, get_startup_data) then
                    game.print("Failures")
                    global.tests_current_test = nil
                    global.tests_setup = nil
                    global.tests_init = nil
                    script.on_nth_tick(event.nth_tick, nil)
                    return
                end
                case.locomotive.destroy()
                global.tests_init = nil
                global.tests_setup = global.tests_setup + 1
            end
        else
            test_runner.teardown(test)
            global.tests_current_test = global.tests_current_test + 1
            global.tests_setup = nil
            global.tests_init = nil
        end
    end
end

local farl_commands = {

    clear_bp = function()
        global._pdata[game.player.index].bp_data = nil
        global._pdata[game.player.index].bp_data2 = nil
    end,

    test_run = function(args)
        render.surface = game.player.surface
        render.player_index = {game.player.index}
        global.tests_current_test = tonumber(args.parameter) or 1
        global.tests_setup = nil
        global.tests_init = nil
        script.on_nth_tick(5, on_nth_tick)
    end,

    save = function()
        --lib.saveVar(pre_rotate, "pre")
        --lib.saveVar(post_rotate, "post")
    end,

    clear_signals = function()
        rendering.clear()
    end,

    foo = function()
        --XxxxxxxYyyyyyyD
        --112345691234567
        --(x+5)*1000000 + (y+5)*1000 + d

        -- local positions = {}
        -- log("hash start")
        -- local h
        -- for i = 1999900, 2000000, 0.5 do
        --     for j = 1999900, 2000000, 0.5 do
        --         for d = 0, 7 do
        --             --print(i, j, d)
        --             h = position_hash(i, j, d)
        --             positions[h] = (positions[h] or 0) + 1
        --         end
        --     end
        -- end
        -- local collisions = 0
        -- local c = 0
        -- for _, k in pairs(positions) do
        --     c = c + 1
        --     if k > 1 then
        --         collisions = collisions + 1
        --     end
        -- end
        -- log("hash stop")
        -- --log2(next(positions))
        -- log("c: " .. c)
        -- log("table_size: " ..table_size(positions))
        -- log("Collisions: " .. collisions)
        do
    local c_entities, c_cases
    local rid_to_hash, sid_to_hash
    local h
    local out
    for tci, test_case in pairs(test_cases) do
        rid_to_hash, sid_to_hash = {}, {}
        c_cases, c_entities = {}, {rails = {}, signals = {}}
        out = {"rails = {"}
        if tci < 6 and tci > 1 then
            for rid, rail in pairs(test_case.created_entities.rails) do
                h = lib.position_hash(rail.position.x, rail.position.y, rail.direction or 0)
                c_entities.rails[h] = rail
                rid_to_hash[rid] = h
                table.insert(out, string.format("[%d] = %s,", h, serpent.line(rail)))
            end
            table.insert(out, "},\nsignals = {")
            for sid, signal in pairs(test_case.created_entities.signals) do
                h = lib.position_hash(signal.position.x, signal.position.y, signal.direction or 0)
                c_entities.signals[h] = signal
                sid_to_hash[sid] = h
                table.insert(out, string.format("[%d] = %s,", h, serpent.line(signal)))
            end
            table.insert(out, "},\ncases = {")
            for i, case in pairs(test_case.cases) do
                if case.signal then
                    case.signal = sid_to_hash[case.signal]
                end
                if case.rail then
                    case.rail = rid_to_hash[case.rail]
                end
                c_cases[i] = serpent.line(case) .. ","
                table.insert(out, c_cases[i])
            end
            table.insert(out, "}")
            log(table_size(c_entities))
            game.write_file("Test" .. tci ..".lua", table.concat(out, "\n"))
        end
    end
end
    end,

    test = function()
        --local _fns = fns
        --fns = {}
        -- local mt = {
        --     __index = function(_, f)
        --         print("*access to element " .. tostring(f))
        --         log(type(_fns[f]))
        --         --print(tostring(...))
        --         --_fns[f](...)
        --         log("foo")
        --     end,

        --     __newindex = function(t,k,v)
        --         print("*update of element " .. tostring(k) ..
        --                             " to " .. tostring(v))
        --         t[k] = v
        --     end,
        -- }
        -- setmetatable(fns, mt)
        local fns = {}

        function fns.test(x)
            --print("Got called with " .. tostring(x))
            return fns.recursive(x, 0, 1)
        end

        function fns.testReturns(a, b, c, d)
            return a, b, c, d
        end

        function fns.recursive(n)
            if n <= 1 then
                return n
            end
            return fns.recursive(n - 1) + fns.recursive(n - 2)
        end

        function fns.recursive2(n, a, b)
            if n == 0 then
                return a
            end
            if n == 1 then
                return b
            end
            return fns.recursive2(n - 1, b, a + b)
        end

        local a, b, c, d = 1, 2, nil, 4

        local a1, b1, c1, d1 = fns.testReturns(a, b, c, d)
        assert(a1 == 1)
        assert(b1 == 2)
        assert(c1 == nil)
        assert(d1 == 4)
        print(tostring(fns.test))

        profiler.Start(false, fns)
        local r = fns.test(9)
        log(r)
        profiler.Stop()

        -- profiler.Start()
        -- -- local r = fns.recursive2(9, 0, 1)
        -- -- log(r)
        -- r = fns.recursive(9)
        -- log(r)
        -- profiler.Stop()

        local p = game.create_profiler()
        fns.test(9)
        p.stop()
        log{"", "bare bones ", p}
    end,
}

for name, f in pairs(farl_commands) do
    commands.add_command("farl_" .. name, "", f)
end