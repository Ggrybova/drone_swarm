-module(drone_swarm_allocation_SUITE).

%% API
-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    test_grid_1x1/1,
    test_grid_1x5/1,
    test_grid_3x3/1,
    test_grid_6x4/1
]).

-define(SETTLE, 10000).

-include_lib("eunit/include/eunit.hrl").

all() ->
    [Fun || {Fun, 1} <- ?MODULE:module_info(exports),
        lists:prefix("test_", atom_to_list(Fun))].

init_per_testcase(_C, Config) -> Config.
end_per_testcase(_C, _Config) -> ok.

test_grid_1x1(_) -> check_all({1, 1}, [1, 2, 5]).
test_grid_1x5(_) -> check_all({1, 5}, [1, 2, 5, 6]).
test_grid_3x3(_) -> check_all({3, 3}, [1, 2, 5, 9, 10, 14]).
test_grid_6x4(_) -> check_all({6, 4}, [1, 3, 8, 24, 30]).

check_all(Grid, Counts) ->
    lists:foreach(fun(N) -> check_one(Grid, N) end, Counts).

check_one({W, L} = Grid, NumDrones) ->
    NumZones = W * L,
    application:set_env(drone_swarm, grid_dim, Grid),
    application:set_env(drone_swarm, num_drones, NumDrones),
    application:set_env(drone_swarm, chaos_interval, 3600000),
    {ok, _} = application:ensure_all_started(drone_swarm),
    ExpectedZones = test_lib:expected_zones(Grid),
    ExpectedBusy = min(NumZones, NumDrones),
    try
        ok = test_lib:wait_full_coverage(Grid, NumDrones, ?SETTLE),
        #{assignments := ZA, unassigned := Un} = drone_swarm_coordinator:status(),
        CoveredZones = test_lib:covered_zones(ZA),
        Busy = length([x || {_R, [_|_]} <- maps:values(ZA)]),
        ?assertEqual(ExpectedZones, CoveredZones), %% кожна зона рівно раз
        ?assertEqual([], Un),                      %% пул порожній
        ?assertEqual(NumDrones, map_size(ZA)),     %% усі дрони зареєстровані
        ?assertEqual(ExpectedBusy, Busy)           %% задіяно min(зон, дронів)
    after
        application:stop(drone_swarm)
    end.
