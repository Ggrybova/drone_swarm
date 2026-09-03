-module(drone_swarm_zone_grid_api).

%% API
-export([
    find_adjacent_drone/2,
    select_connected_zones/2
]).
-ifdef(TEST).
-export([
    is_adjacent/2,
    has_adjacent_zone/2,
    find_neighbors/2
]).
-endif.

-export_type([zone/0]).
-type zone() :: {integer(), integer()}.

%% API
-spec find_adjacent_drone(EmptyZones, Drones) -> {ok, pid()} | undefined when
    EmptyZones :: [zone()],
    Drones :: [{pid(), {reference(), [zone()]}}].
find_adjacent_drone(_, []) ->
    undefined;
find_adjacent_drone(EmptyZones, [{Pid, {_, [_ | _] = Zones}} | RestOfDrones]) ->
    case has_adjacent_zone(EmptyZones, Zones) of
        true ->
            {ok, Pid};
        false ->
            find_adjacent_drone(EmptyZones, RestOfDrones)
    end;
find_adjacent_drone(EmptyZones, [{_, {_, []}} | RestOfDrones]) ->
    find_adjacent_drone(EmptyZones, RestOfDrones).

-spec select_connected_zones(MaxCount, ZoneList) -> [zone()] when
    MaxCount :: non_neg_integer() | null,
    ZoneList :: [zone()].
select_connected_zones(MaxCount, ZoneList) ->
    select_connected_zones(MaxCount, ZoneList, [], []).
select_connected_zones(_MaxCount, [] = _Zones, [] = _NeedToCheck, Acc) ->
    Acc;
select_connected_zones(MaxCount, _Zones, _NeedToCheck, Acc) when length(Acc) >= MaxCount ->
    Acc;
select_connected_zones(_MaxCount, [_] = Zones, [] = _NeedToCheck, [] = _Acc) ->
    Zones;
select_connected_zones(MaxCount, Zones, [CurrZone | Rest] = _NeedToCheck0, Acc) ->
    Neighbors0 = find_neighbors(CurrZone, Zones),
    Neighbors = lists:filter(fun(X) -> lists:member(X, Zones) end, Neighbors0),
    NeedToCheck = lists:usort(Rest ++ Neighbors),
    select_connected_zones(MaxCount, Zones -- [CurrZone], NeedToCheck, [CurrZone | Acc]);
select_connected_zones(MaxCount, [CurrZone | Zones], NeedToCheck, Acc) ->
    Neighbors0 = find_neighbors(CurrZone, Zones),
    Neighbors = lists:filter(fun(X) -> lists:member(X, Zones) end, Neighbors0),
    case Neighbors of
        [_|_] ->
            NeedToCheckNew = lists:usort(Neighbors),
            select_connected_zones(MaxCount, Zones, NeedToCheckNew, [CurrZone | Acc]);
        [] ->
            select_connected_zones(MaxCount, Zones, NeedToCheck, Acc)
    end.

%% Internal API
find_neighbors(CurrZoneCoords, Zones) ->
    Fun =
        fun (ZoneCoords, NeighborsAcc) when ZoneCoords =:= CurrZoneCoords -> NeighborsAcc;
            (ZoneCoords, NeighborsAcc) ->
                case is_adjacent(CurrZoneCoords, ZoneCoords) of
                    true -> [ZoneCoords | NeighborsAcc];
                    false -> NeighborsAcc
                end
        end,
    lists:foldl(Fun, [], Zones).

has_adjacent_zone(EmptyZones, [Zone | RestOfZones]) ->
    Fun = fun(EmptyZone) -> is_adjacent(EmptyZone, Zone) end,
    case lists:any(Fun, EmptyZones) of
        true -> true;
        false -> has_adjacent_zone(EmptyZones, RestOfZones)
    end;
has_adjacent_zone(_EmptyZones, []) ->
    false.

is_adjacent({R1, C1}, {R2, C2}) ->
    (abs(R1 - R2) =:= 1 andalso C1 =:= C2) orelse (abs(C1 - C2) =:= 1 andalso R1 =:= R2).
