-module(drone_swarm_zone_grid).

%% API
-export([
    find_adjacent_drone/2,
    select_connected_zones/2
]).
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
select_connected_zones(MaxCount, Zones, [CurrZone | Rest] = _NeedToCheck0, Acc) ->
%%    io:format("~n *1* MaxCount: ~p Zones: ~p~n     NeedToCheck: ~p ~p~n    Acc: ~p~n" , [MaxCount, Zones, CurrZoneId, Rest, Acc]),
    Neighbors = find_neighbors(CurrZone, Zones),
    Fun = fun(X) -> lists:member(X, Zones) andalso X > CurrZone end,
    FilteredNeighbors = lists:filter(Fun, Neighbors),
    NewAcc = lists:usort([CurrZone | Acc]), %% прибрати usort
    NeedToCheck = lists:usort(Rest ++ FilteredNeighbors),
    select_connected_zones(MaxCount, Zones -- [CurrZone], NeedToCheck, NewAcc);
select_connected_zones(MaxCount, [CurrZone | Zones], NeedToCheck, Acc) ->
%%    io:format("~n *2* MaxCount: ~p CurrZoneId: ~p Zones: ~p~n     NeedToCheck: ~p~n    Acc: ~p~n" , [MaxCount, CurrZoneId, Zones, NeedToCheck, Acc]),
    Neighbors = find_neighbors(CurrZone, Zones),
    FilteredNeighbors = lists:filter(fun(X) -> lists:member(X, Zones) end, Neighbors),
    case FilteredNeighbors of
        [_|_] ->
            NeedToCheckNew = lists:usort(FilteredNeighbors),
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
