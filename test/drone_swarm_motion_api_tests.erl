-module(drone_swarm_motion_api_tests).

-include_lib("eunit/include/eunit.hrl").

-define(BLOCK_SIZE, {10, 15}).
-define(GRID_DIM, {3, 3}).


init_pos_origin_test() ->
    ?assertEqual({0, 0}, drone_swarm_motion_api:init_pos({0, 0}, ?BLOCK_SIZE)).

get_max_cell_test() ->
    ?assertEqual({30, 45}, drone_swarm_motion_api:get_max_cell(?BLOCK_SIZE, ?GRID_DIM)),
    ?assertEqual({10, 20}, drone_swarm_motion_api:get_max_cell({5, 5}, {2, 4})).

get_adjacent_cells_middle_test() ->
    Result = lists:sort(drone_swarm_motion_api:get_adjacent_cells({10, 10}, {30, 45})),
    ?assertEqual(lists:sort([{9, 10}, {11, 10}, {10, 9}, {10, 11}]), Result).

get_adjacent_cells_origin_clips_negative_test() ->
    Result = lists:sort(drone_swarm_motion_api:get_adjacent_cells({0, 0}, {30, 45})),
    ?assertEqual(lists:sort([{1, 0}, {0, 1}]), Result).

get_adjacent_cells_far_corner_clips_over_max_test() ->
    Result = lists:sort(drone_swarm_motion_api:get_adjacent_cells({30, 45}, {30, 45})),
    ?assertEqual(lists:sort([{29, 45}, {30, 44}]), Result).

check_cell_inside_zone_test() ->
    ?assert(drone_swarm_motion_api:check_cell({5, 5}, [{0, 0}], ?BLOCK_SIZE)).

check_cell_outside_zone_test() ->
    ?assertNot(drone_swarm_motion_api:check_cell({10, 5}, [{0, 0}], ?BLOCK_SIZE)).

check_cell_zone_upper_boundary_inclusive_test() ->
    %% zone {0,0} box spans X:0..9, Y:0..14 for block {10,15}
    ?assert(drone_swarm_motion_api:check_cell({9, 14}, [{0, 0}], ?BLOCK_SIZE)),
    ?assertNot(drone_swarm_motion_api:check_cell({10, 14}, [{0, 0}], ?BLOCK_SIZE)),
    ?assertNot(drone_swarm_motion_api:check_cell({9, 15}, [{0, 0}], ?BLOCK_SIZE)).

check_cell_matches_second_zone_test() ->
    ?assert(drone_swarm_motion_api:check_cell({15, 5}, [{0, 0}, {1, 0}], ?BLOCK_SIZE)).

check_cell_empty_zones_test() ->
    ?assertNot(drone_swarm_motion_api:check_cell({5, 5}, [], ?BLOCK_SIZE)).

move_stays_within_single_zone_test() ->
    %% CurrPos well inside zone {0,0} (box X:0-9,Y:0-14) - all 4 neighbors valid
    Result = drone_swarm_motion_api:move({5, 5}, [{0, 0}], ?BLOCK_SIZE, ?GRID_DIM),
    ?assert(lists:member(Result, [{4, 5}, {6, 5}, {5, 4}, {5, 6}])).

move_respects_map_lower_bound_test() ->
    %% CurrPos at map corner {0,0} - only {1,0} and {0,1} are valid candidates
    Result = drone_swarm_motion_api:move({0, 0}, [{0, 0}], ?BLOCK_SIZE, ?GRID_DIM),
    ?assert(lists:member(Result, [{1, 0}, {0, 1}])).

move_avoids_crossing_zone_boundary_test() ->
    %% CurrPos on zone {0,0}'s right edge (X=9): moving to X=10 leaves the zone
    Result = drone_swarm_motion_api:move({9, 7}, [{0, 0}], ?BLOCK_SIZE, ?GRID_DIM),
    ?assert(lists:member(Result, [{8, 7}, {9, 6}, {9, 8}])),
    ?assertNotEqual({10, 7}, Result).

move_returns_curr_pos_when_no_zones_test() ->
    ?assertEqual({5, 5}, drone_swarm_motion_api:move({5, 5}, [], ?BLOCK_SIZE, ?GRID_DIM)).

move_stays_inside_zone_over_many_trials_test() ->
    Fun = fun(_, Pos) ->
        Next = drone_swarm_motion_api:move(Pos, [{0, 0}], ?BLOCK_SIZE, ?GRID_DIM),
        ?assert(drone_swarm_motion_api:check_cell(Next, [{0, 0}], ?BLOCK_SIZE)),
        Next
          end,
    lists:foldl(Fun, {5, 5}, lists:seq(1, 100)).

move_crosses_between_owned_adjacent_zones_test() ->
    Zones = [{0, 0}, {1, 0}],
    Trajectory = lists:foldl(
        fun(_, [Pos | _] = Acc) ->
            [drone_swarm_motion_api:move(Pos, Zones, ?BLOCK_SIZE, ?GRID_DIM) | Acc]
        end, [{9, 7}], lists:seq(1, 300)),
    Xs = [X || {X, _} <- Trajectory],
    ?assert(lists:any(fun(X) -> X >= 10 end, Xs)),
    ?assert(lists:any(fun(X) -> X =< 9 end, Xs)).


