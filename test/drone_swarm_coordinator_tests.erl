-module(drone_swarm_coordinator_tests).

-include_lib("eunit/include/eunit.hrl").

rebalance_keeps_remaining_zones_connected_test() ->
    Zones = [{2, 2}, {1, 2}, {0, 2}, {0, 1}, {0, 0}],
    MostLoaded = {fake_pid(), length(Zones), Zones, {2, 2}},
    {Taken, Kept} = drone_swarm_coordinator:rebalance_zones(fake_pid(), MostLoaded, 2),
    ?assertEqual(2, length(Taken)),
    ?assert(lists:member({2, 2}, Kept)),
    ?assert(connected(Taken)),
    ?assert(connected(Kept)).

connected(Zones) ->
    length(drone_swarm_zone_grid_api:select_connected_zones(null, Zones)) =:= length(Zones).

fake_pid() ->
    spawn(fun() -> ok end).
