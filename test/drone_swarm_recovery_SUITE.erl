-module(drone_swarm_recovery_SUITE).

%% API
-export([all/0]).
-export([init_per_testcase/2, end_per_testcase/2]).

-export([
    test_restart_preserves_coverage/1,
    test_restart_while_charging/1
]).

-define(GRID_6X4, {6, 4}).
-define(NUM_DRONES_6, 6).

-include_lib("eunit/include/eunit.hrl").

all() ->
    [Fun || {Fun, 1} <- ?MODULE:module_info(exports),
        lists:prefix("test_", atom_to_list(Fun))].

init_per_testcase(_TestCase, Config) ->
    Grid = ?GRID_6X4,
    NumDrones = ?NUM_DRONES_6,
    application:set_env(drone_swarm, grid_dim, Grid),
    application:set_env(drone_swarm, num_drones, NumDrones),
    application:set_env(drone_swarm, chaos_interval, 20000),
    {ok, _} = application:ensure_all_started(drone_swarm),
    ok = test_lib:wait_full_coverage(Grid, NumDrones, 20000),
    Config.

end_per_testcase(_Case, Config) ->
    _ = application:stop(drone_swarm),
    Config.

test_restart_preserves_coverage(_Config) ->
    Grid = ?GRID_6X4,
    NumDrones = ?NUM_DRONES_6,
    Expected = test_lib:expected_zones(Grid),
    DronesBefore = drone_pids(),
    Old = whereis(drone_swarm_coordinator),
    ok = drone_swarm_chaos_monkey:kill_coordinator(),
    ok = wait_for_new_pid(drone_swarm_coordinator, Old, 5000),
    ok = test_lib:wait_full_coverage(Grid, NumDrones, 20000),
    #{assignments := ZA, unassigned := Un} = drone_swarm_coordinator:status(),
    CoveredZones = test_lib:covered_zones(ZA),
    ?assertEqual(Expected, CoveredZones),     %% усі 24 зони, кожна раз (дубль -> довжина ≠ 24)
    ?assertEqual([], Un),                     %% пул порожній
    ?assertEqual(NumDrones, map_size(ZA)),    %% resync перереєстрував усіх
    ?assertEqual(DronesBefore, drone_pids()). %% one_for_one не чіпав workers_sup

test_restart_while_charging(_Config) ->
    Grid = ?GRID_6X4,
    NumDrones = ?NUM_DRONES_6,
    Expected = test_lib:expected_zones(Grid),
    Old = whereis(drone_swarm_coordinator),

    %% дочекатись battery_low -> charging (BATTERY_LOW_TIMEOUT=5000 у TEST)
    ok = wait_charging_drone(NumDrones, 15000),
    ok = drone_swarm_chaos_monkey:kill_coordinator(),
    ok = wait_for_new_pid(drone_swarm_coordinator, Old, 5000),
    ok = test_lib:wait_full_coverage(Grid, NumDrones, 20000), %% resync + повернення зарядженого дрона + rebalance

    #{assignments := ZA, unassigned := Un} = drone_swarm_coordinator:status(),
    ?assertEqual(Expected, test_lib:covered_zones(ZA)), %% 24 зони; стейл дав би 28 -> ≠
    ?assertEqual([], Un),                               %% пул порожній
    ?assertEqual(NumDrones, map_size(ZA)),              %% resync перереєстрував усіх
    ?assertEqual(1, max_multiplicity(ZA)).              %% жодна зона не в двох дронів

drone_pids() ->
    lists:sort([P || {_, P, _, _} <- supervisor:which_children(drone_swarm_workers_sup),
        is_pid(P)]).

wait_for_new_pid(Name, Old, T) ->
    Fun = fun() ->
        case whereis(Name) of
            undefined -> false;
            Old -> false;
            _ -> true
        end
    end,
    test_lib:wait_until(Fun, T).

wait_charging_drone(NumDrones, T) ->
    Fun = fun() ->
        case drone_swarm_coordinator:status() of
            #{assignments := ZA} when map_size(ZA) =:= NumDrones ->
                %% NumDrones =< NumZones, тож [] однозначно = charging, не surplus
                lists:any(fun({_R, []}) -> true; (_) -> false end, maps:values(ZA));
            _ -> false
        end
    end,
    test_lib:wait_until(Fun, T).

max_multiplicity(ZoneAssignments) ->
    All  = lists:append([Zs || {_R, Zs} <- maps:values(ZoneAssignments)]),
    Freq = lists:foldl(fun(Z, A) -> maps:update_with(Z, fun(N) -> N + 1 end, 1, A) end, #{}, All),
    lists:max([1 | maps:values(Freq)]).
