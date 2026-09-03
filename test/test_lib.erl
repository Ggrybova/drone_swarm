-module(test_lib).

%% API
-export([
    expected_zones/1,
    covered_zones/1,
    wait_full_coverage/3,
    wait_until/2
]).

expected_zones({Width, Length}) ->
    lists:sort([{Val div Length, Val rem Length} ||
        Val <- lists:seq(0, Width * Length - 1)]).

covered_zones(ZoneAssignments) ->
    lists:sort(lists:append([Zs || {_R, Zs} <- maps:values(ZoneAssignments)])).

wait_full_coverage(Grid, NumDrones, T) ->
    Fun = fun() -> full_coverage(Grid, NumDrones) end,
    wait_until(Fun, T).

wait_until(_Fun, Timeout) when Timeout =< 0 ->
    {error, timeout};
wait_until(Fun, Timeout) ->
    case (try Fun() catch _:_ -> false end) of
        true -> ok;
        _    -> timer:sleep(50), wait_until(Fun, Timeout - 50)
    end.

%% Internal
full_coverage({Width, Length} = _Grid, NumDrones) ->
    Status = try drone_swarm_coordinator:status() catch _:_ -> undefined end,
    case Status of
        #{assignments := ZA, unassigned := []} when map_size(ZA) =:= NumDrones ->
            Vs = maps:values(ZA),
            Covered = lists:sort(lists:append([Zs || {_R, Zs} <- Vs])),
            Busy = length([x || {_R, [_|_]} <- Vs]),
            ExpectedZones = expected_zones({Width, Length}),
            ExpectedBusy = min(Width * Length, NumDrones),
            Covered =:= ExpectedZones andalso Busy =:= ExpectedBusy;
        _ -> false
    end.
