-module(drone_swarm_zone_grid_tests).

-include_lib("eunit/include/eunit.hrl").

-define(GRID_3X3, [{0,0},{0,1},{0,2},{1,0},{1,1},{1,2},{2,0},{2,1},{2,2}]).

is_adjacent_test() ->
    ?assert(drone_swarm_zone_grid:is_adjacent({2, 2}, {1, 2})),
    ?assert(drone_swarm_zone_grid:is_adjacent({4, 4}, {4, 5})),
    ?assert(drone_swarm_zone_grid:is_adjacent({1, 3}, {2, 3})),
    ?assert(drone_swarm_zone_grid:is_adjacent({3, 5}, {3, 4})),
    ?assertNot(drone_swarm_zone_grid:is_adjacent({1, 1}, {1, 1})),
    ?assertNot(drone_swarm_zone_grid:is_adjacent({1, 0}, {2, 1})),
    ?assertNot(drone_swarm_zone_grid:is_adjacent({4, 1}, {1, 4})),
    ?assertNot(drone_swarm_zone_grid:is_adjacent({2, 2}, {4, 2})),
    ?assertNot(drone_swarm_zone_grid:is_adjacent({5, 3}, {4, 4})),
    ?assertNot(drone_swarm_zone_grid:is_adjacent({0, 0}, {7, 7})).

has_adjacent_zone_test() ->
    ?assert(drone_swarm_zone_grid:has_adjacent_zone([{1, 1}], [{2,0}, {2,1}, {2,2}, {2,3}])),
    ?assert(drone_swarm_zone_grid:has_adjacent_zone([{2, 2}], [{5,0}, {4,3}, {2,6}, {1,2}, {3,3}])),
    ?assert(drone_swarm_zone_grid:has_adjacent_zone([{7, 7}, {4,4}], [{5,0}, {4,3}, {2,6}, {1,2}, {3,3}])),
    ?assertNot(drone_swarm_zone_grid:has_adjacent_zone([{2, 4}], [{0,0}, {4,3}, {2,6}, {1,2}, {3,3}])),
    ?assertNot(drone_swarm_zone_grid:has_adjacent_zone([{3, 3}, {5, 5}], [{2,2}, {2,4}, {4,2}, {4,4}])).

find_neighbors_test() ->
    ?assertEqual([{2,1}], drone_swarm_zone_grid:find_neighbors({1, 1}, [{2,0}, {2,1}, {2,2}, {2,3}])),
    ?assertEqual([{3,2}, {2,3}, {1,2}, {2,1}], drone_swarm_zone_grid:find_neighbors({2, 2}, [{1,1}, {2,1}, {1,3}, {1,2}, {2,3}, {3,1}, {3,3}, {3,2}])),
    ?assertEqual([{3,4}], drone_swarm_zone_grid:find_neighbors({4,4}, [{5,0}, {3,4}, {2,6}, {1,2}, {3,3}])),
    ?assertEqual([], drone_swarm_zone_grid:find_neighbors({3, 2}, [{2,4}, {1,4}, {1,3}, {1,2}, {0,4}, {1,1}, {2,3}, {4,4}, {5,4}, {5,3}, {5,2}, {5,1}, {4,1}])).

select_connected_zones_empty_list_test() ->
    ?assertEqual([], drone_swarm_zone_grid:select_connected_zones(2, [])).

select_connected_zones_zero_max_count_test() ->
    ?assertEqual([], drone_swarm_zone_grid:select_connected_zones(0, [{0,3}])).

select_connected_zones_single_zone_test() ->
    ?assertEqual([{0,3}], drone_swarm_zone_grid:select_connected_zones(null, [{0,3}])).

select_connected_zones_returns_one_zone_when_none_connected_test() ->
    ?assertEqual([{2,3}], drone_swarm_zone_grid:select_connected_zones(null, [{0,3}, {2,3}])).

select_connected_zones_prefers_real_group_over_isolated_test() ->
    Result = drone_swarm_zone_grid:select_connected_zones(null, [{0,0}, {2,2}, {2,3}]),
    ?assertEqual(lists:sort([{2,2}, {2,3}]), lists:sort(Result)).

select_connected_zones_small_group_test() ->
    Expected = [{1,1},{1,2},{1,3},{0,3}],
    Result = drone_swarm_zone_grid:select_connected_zones(null, [{0,3}, {1,1}, {1,2}, {1,3}]),
    ?assertEqual(lists:sort(Expected), lists:sort(Result)).

select_connected_zones_cross_shape_test() ->
    Expected = [{2,1},{1,2},{1,0},{1,1},{0,1}],
    Result = drone_swarm_zone_grid:select_connected_zones(null, [{0,1}, {1,0}, {1,1}, {1,2}, {2,1}]),
    ?assertEqual(lists:sort(Expected), lists:sort(Result)).

select_connected_zones_arbitrary_group_test() ->
    Expected = [{5,4},{5,3},{4,3}],
    Result = drone_swarm_zone_grid:select_connected_zones(null, [{4,3}, {5,1}, {0,3}, {3,4}, {2,1}, {5,3}, {5,4}]),
    ?assertEqual(lists:sort(Expected), lists:sort(Result)).

select_connected_zones_respects_max_count_one_test() ->
    ?assertEqual([{0,0}], drone_swarm_zone_grid:select_connected_zones(1, ?GRID_3X3)).

select_connected_zones_respects_max_count_two_test() ->
    Result = drone_swarm_zone_grid:select_connected_zones(2, ?GRID_3X3),
    ?assertEqual(lists:sort([{0,0},{0,1}]), lists:sort(Result)).

select_connected_zones_null_returns_all_connected_test() ->
    Result = drone_swarm_zone_grid:select_connected_zones(null, ?GRID_3X3),
    ?assertEqual(lists:sort(?GRID_3X3), lists:sort(Result)).

find_adjacent_drone_no_drones_test() ->
    ?assertEqual(undefined, drone_swarm_zone_grid:find_adjacent_drone([{0,0}], [])).

find_adjacent_drone_found_test() ->
    Drones = [{drone_a, {make_ref(), [{0,0}, {0,1}]}}],
    ?assertEqual({ok, drone_a}, drone_swarm_zone_grid:find_adjacent_drone([{0,2}], Drones)).

find_adjacent_drone_not_found_test() ->
    Drones = [{drone_a, {make_ref(), [{0,0}, {0,1}]}}],
    ?assertEqual(undefined, drone_swarm_zone_grid:find_adjacent_drone([{5,5}], Drones)).

find_adjacent_drone_skips_drones_with_no_zones_test() ->
    Drones = [{drone_a, {make_ref(), []}}, {drone_b, {make_ref(), [{0,0}]}}],
    ?assertEqual({ok, drone_b}, drone_swarm_zone_grid:find_adjacent_drone([{0,1}], Drones)).

find_adjacent_drone_skips_non_adjacent_drone_with_zones_test() ->
    Drones = [{drone_a, {make_ref(), [{5,5}]}}, {drone_b, {make_ref(), [{0,0}, {0,1}]}}],
    ?assertEqual({ok, drone_b}, drone_swarm_zone_grid:find_adjacent_drone([{0,2}], Drones)).

find_adjacent_drone_returns_first_match_test() ->
    Drones = [{drone_a, {make_ref(), [{0,1}]}}, {drone_b, {make_ref(), [{0,3}]}}],
    ?assertEqual({ok, drone_a}, drone_swarm_zone_grid:find_adjacent_drone([{0,2}], Drones)).

find_adjacent_drone_empty_zones_list_test() ->
    Drones = [{drone_a, {make_ref(), [{0,0}]}}],
    ?assertEqual(undefined, drone_swarm_zone_grid:find_adjacent_drone([], Drones)).
