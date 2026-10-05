-module(drone_swarm_coordinator).
-behaviour(gen_server).

-export([start_link/1]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    handle_continue/2,
    terminate/2,
    code_change/3
]).

-define(SERVER, ?MODULE).
-define(DEF_GRID_DIM, {3, 3}).
-ifdef(TEST).
-export([status/0]).
-define(RESYNC_WINDOW, 2000).
-else.
-define(RESYNC_WINDOW, 800).
-endif.

-include_lib("kernel/include/logger.hrl").

-type zone() :: drone_swarm_zone_grid_api:zone().

-record(state, {
    unassigned_zones :: [zone()], %% список пустих зон
    max_zones_per_drone :: integer(), %% макс.початкова кількість зон на дрона
    zone_assignments = #{} :: map(),  %% #{drone_pid::pid() => {ref(), [zone()]}}
                                     %% звʼязка дрон - зони
    drone_locations = #{} :: map(),  %% #{drone_pid::pid() => zone()}
    resyncing = false :: boolean(), %% true поки координатор відновлює стан після рестарту
    deferred = [] :: [term()] %% get_drone/battery_low/zones_declined, відкладені на час resync
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

-spec start_link(NumDrones :: pos_integer()) -> {ok, pid()} | {error, term()}.
start_link(NumDrones) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [NumDrones], []).

-ifdef(TEST).
status() ->
    gen_server:call(?SERVER, status).
-endif.

init([NumDrones]) ->
    {GridWidth, GridLength} = application:get_env(drone_swarm, grid_dim, ?DEF_GRID_DIM),
    NumZones = GridWidth * GridLength,
    MaxZonesPerDrone = round(NumZones / NumDrones),
    Zones = [{ZoneId div GridLength, ZoneId rem GridLength} ||
        ZoneId <- lists:seq(0, NumZones - 1)],
    State = #state{
        unassigned_zones = Zones,
        max_zones_per_drone = MaxZonesPerDrone
    },
    {ok, State, {continue, resync}}.

handle_call(status, _From, #state{zone_assignments = ZA, unassigned_zones = Un} = State) ->
    {reply, #{assignments => ZA, unassigned => Un}, State};
handle_call(_Request, _From, #state{} = State) ->
    {reply, ok, State}.

handle_cast({Type, _} = Msg, #state{resyncing = true, deferred = D} = State)
    when Type =:= get_drone orelse Type =:= battery_low ->
    {noreply, State#state{deferred = [Msg | D]}};
handle_cast({zones_declined, _, _} = Msg, #state{resyncing = true, deferred = D} = State) ->
    {noreply, State#state{deferred = [Msg | D]}};
handle_cast({get_drone, Pid}, #state{zone_assignments = ZoneAssignment,
    unassigned_zones = [_ | _] = UnassignedZoneIds} = State) ->
    MRef = monitor_drone(Pid, ZoneAssignment),
    ConnectedZones = drone_swarm_zone_grid_api:select_connected_zones(null, UnassignedZoneIds),
    Rest = UnassignedZoneIds -- ConnectedZones,
    Rest =/= [] andalso logger:info("!!! ConnectedZones: ~p, Rest: ~p", [ConnectedZones, Rest]),
    gen_statem:cast(Pid, {assign_zones, ConnectedZones}),
%%    logger:info(" *  ASIGN  ~p -> ~p", [Pid, ConnectedZones]),
    NewState = State#state{
        unassigned_zones = Rest,
        zone_assignments = ZoneAssignment#{Pid => {MRef, ConnectedZones}}},
    {noreply, NewState};
handle_cast({get_drone, Pid}, #state{zone_assignments = ZoneAssignment,
    max_zones_per_drone = MaxZonesPerDrone, drone_locations = DroneLocations} = State) ->
    MRef = monitor_drone(Pid, ZoneAssignment),
    {MostLoadedDronePid, ZonesCount} = find_most_loaded_drone(ZoneAssignment),
    {MRef2, ZoneList} = maps:get(MostLoadedDronePid, ZoneAssignment),
    DroneLocation = maps:get(MostLoadedDronePid, DroneLocations, null),
    MostLoadedDrone = {MostLoadedDronePid, ZonesCount, ZoneList, DroneLocation},
    {ZonesToRemove, ZonesToKeep} = rebalance_zones(Pid, MostLoadedDrone, MaxZonesPerDrone),
    NewZoneAssignment = ZoneAssignment#{
        Pid => {MRef, ZonesToRemove},
        MostLoadedDronePid => {MRef2, ZonesToKeep}
    },
    {noreply, State#state{zone_assignments = NewZoneAssignment}};
handle_cast({battery_low, Pid}, #state{zone_assignments = ZoneAssignment} = State)
    when is_map_key(Pid, ZoneAssignment) ->
    {MRef, EmptyZones} = maps:get(Pid, ZoneAssignment),
%%    logger:info("  * {batary_low, ~p}~n Ass-nt: ~p", [Pid, ZoneAssignment]),
    case reassign_zones(Pid, ZoneAssignment) of
        {ok, NewZoneAssignment} ->
            NewState = State#state{
                zone_assignments = NewZoneAssignment#{Pid => {MRef, []}}
            },
            {noreply, NewState};
        {notfound, NewZoneAssignment} ->
            UnassignedZoneIds = State#state.unassigned_zones,
            logger:info("!!! {batary_low, ~p} ZONES NOTFOUND~n zones ~p -> unassigned",
                [Pid, EmptyZones]),
            NewState = State#state{
                zone_assignments = NewZoneAssignment#{Pid => {MRef, []}},
                unassigned_zones = lists:usort(UnassignedZoneIds ++ EmptyZones)
            },
            {noreply, NewState}
    end;
handle_cast({battery_low, Pid}, State) ->
    logger:info("!!! {battery_low, ~p}: unknown drone (coordinator restart?), ignoring", [Pid]),
    {noreply, State};
handle_cast({zones_declined, Pid, Zones}, #state{zone_assignments = ZoneAssignment,
    unassigned_zones = UnassignedZoneIds} = State) when is_map_key(Pid, ZoneAssignment) ->
    {MRef, _} = maps:get(Pid, ZoneAssignment),
    logger:info("!!! {zones_declined, ~p}: zones ~p -> unassigned", [Pid, Zones]),
    NewState = State#state{
        zone_assignments = ZoneAssignment#{Pid => {MRef, []}},
        unassigned_zones = lists:usort(UnassignedZoneIds ++ Zones)
    },
    {noreply, NewState};
handle_cast({zones_declined, Pid, _Zones}, State) ->
    logger:info("!!! {zones_declined, ~p}: unknown drone (coordinator restart?), ignoring", [Pid]),
    {noreply, State};
handle_cast({zones_report, Pid, Zones}, #state{zone_assignments = ZoneAssignment,
    unassigned_zones = UnassignedZoneIds, resyncing = Resyncing} = State) ->
    case {Resyncing, maps:find(Pid, ZoneAssignment)} of
        {false, {ok, {_MRef, [_ | _] = Have}}} ->
            logger:info(" * пізній zones_report від ~p (уже має ~p), ігнорую", [Pid, Have]),
            {noreply, State};
        {_, _} ->
            MRef = monitor_drone(Pid, ZoneAssignment),
            logger:info(" * resync: ~p -> ~p", [Pid, Zones]),
            {noreply, State#state{
                zone_assignments = ZoneAssignment#{Pid => {MRef, Zones}},
                unassigned_zones = UnassignedZoneIds -- Zones
            }}
    end;
handle_cast({drone_location, Pid, DroneLocation},
    #state{drone_locations = DroneLocations} = State) ->
    OldLocation = maps:get(Pid, DroneLocations, undefined),
    logger:info("!!! {drone_location, ~p}: ~nold location ~p~nnew location ~p",
        [Pid, OldLocation, DroneLocation]),
    NewState = State#state{
        drone_locations = DroneLocations#{Pid => DroneLocation}
    },
    {noreply, NewState};
handle_cast(_Request, #state{} = State) ->
    {noreply, State}.

handle_continue(resync, #state{} = State) ->
    case whereis(drone_swarm_workers_sup) of
        undefined ->
            %% перший старт: workers_sup ще не піднятий, дрони самі звернуться через get_drone
            {noreply, State};
        SupPid ->
            Children = supervisor:which_children(SupPid),
            Drones = [Pid || {_Id, Pid, _Type, _Mod} <- Children, is_pid(Pid)],
            case Drones of
                [] ->
                    {noreply, State};
                [_ | _] ->
                    ZoneAssignment = resync(Drones),
                    NewState = State#state{
                        zone_assignments = ZoneAssignment,
                        resyncing = true
                    },
                    {noreply, NewState}
            end
    end.

handle_info({'DOWN', MRef, process, Pid, Reason},
    #state{zone_assignments = ZoneAssignment} = State)
    when is_map_key(Pid, ZoneAssignment) ->
    {MRef, EmptyZones} = maps:get(Pid, ZoneAssignment),
%%    logger:info(" * ~p was ~p EmptyZones: ~p~n", [Pid, Reason, EmptyZones]),
    case reassign_zones(Pid, ZoneAssignment) of
        {ok, NewZoneAssignment} ->
            NewState = State#state{zone_assignments = NewZoneAssignment},
            {noreply, NewState};
        {notfound, NewZoneAssignment} ->
            UnassignedZoneIds = State#state.unassigned_zones,
            logger:info("!!! {~p, ~p} ZONES NOTFOUND~n zones ~p -> unassigned",
                [Reason, Pid, EmptyZones]),
            NewState = State#state{
                zone_assignments = NewZoneAssignment,
                unassigned_zones = lists:usort(UnassignedZoneIds ++ EmptyZones)
            },
            {noreply, NewState}
    end;
handle_info({'DOWN', _MRef, process, Pid, Reason}, #state{} = State) ->
    logger:info("!!!  ~p was ~p ", [Pid, Reason]),
    {noreply, State};
handle_info(resync_done, #state{deferred = Deferred} = State) ->
    lists:foreach(fun(Msg) -> gen_server:cast(self(), Msg) end, lists:reverse(Deferred)),
    logger:info(" * resync завершено, програю ~p відкладених", [length(Deferred)]),
    {noreply, State#state{resyncing = false, deferred = []}};
handle_info(Info, #state{} = State) ->
    logger:info("!!!  ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #state{} = _State) ->
    ok.

code_change(_OldVsn, #state{} = State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
resync(Drones) ->
    ZoneAssignment = lists:foldl(
        fun(Pid, Acc) ->
            MRef = erlang:monitor(process, Pid),
            gen_statem:cast(Pid, {request_zones, self()}),
            Acc#{Pid => {MRef, []}}
        end, #{}, Drones),
    erlang:send_after(?RESYNC_WINDOW, self(), resync_done),
    logger:info(" * resync: запит зон у ~p дронів", [length(Drones)]),
    ZoneAssignment.

reassign_zones(Pid, ZoneAssignment) ->
    {_, EmptyZones} = maps:get(Pid, ZoneAssignment),
    ZoneAssignment2 = maps:without([Pid], ZoneAssignment),
    ZoneAssignmentList = lists:sort(
        fun({_Key1, {_, List1}}, {_Key2, {_, List2}}) -> length(List1) =< length(List2) end,
        maps:to_list(ZoneAssignment2)
    ),
    case drone_swarm_zone_grid_api:find_adjacent_drone(EmptyZones, ZoneAssignmentList) of
        {ok, LeastLoadedDronePid} ->
            {MRef, Zones} = maps:get(LeastLoadedDronePid, ZoneAssignment2),
            NewZones = Zones ++ EmptyZones,
            gen_statem:cast(LeastLoadedDronePid, {assign_zones, NewZones}),
            NewZoneAssignment = ZoneAssignment2#{LeastLoadedDronePid => {MRef, NewZones}},
            {ok, NewZoneAssignment};
        undefined ->
            {notfound, ZoneAssignment2}
    end.

find_most_loaded_drone(ZoneAssignment) ->
    Fun = fun(Drone, {_Ref, Zones}, {_, MaxLength} = Acc) ->
        Length = length(Zones),
        case Length > MaxLength of
            true -> {Drone, Length};
            false -> Acc
        end
    end,
    maps:fold(Fun, {undefined, 0}, ZoneAssignment).

rebalance_zones(Pid, {MostLoadedDronePid, ZonesCount, ZoneList, DroneLocation}, MaxZonesPerDrone) ->
    RemainingZonesCount = remaining_zones_count(Pid, ZonesCount, MaxZonesPerDrone),
    ZonesToRemove = case DroneLocation of
        null ->
            drone_swarm_zone_grid_api:select_connected_zones(RemainingZonesCount, ZoneList);
        {_, _} = Zone ->
            drone_swarm_zone_grid_api:select_connected_zones(
                RemainingZonesCount, ZoneList -- [Zone])
    end,
    ZonesToKeep = ZoneList -- ZonesToRemove,
    case ZonesToRemove =/= [] of
        true ->
            gen_statem:cast(MostLoadedDronePid, {unassign_zones, ZonesToRemove}),
            gen_statem:cast(Pid, {assign_zones, ZonesToRemove});
        false ->
            ok
    end,
    {ZonesToRemove, ZonesToKeep}.

remaining_zones_count(_Pid, ZonesCount, MaxZonesPerDrone) when ZonesCount > MaxZonesPerDrone ->
    MaxZonesPerDrone;
remaining_zones_count(_Pid, ZonesCount, MaxZonesPerDrone) when ZonesCount =:= MaxZonesPerDrone ->
    MaxZonesPerDrone - 1;
remaining_zones_count(_Pid, ZonesCount, _MaxZonesPerDrone) when ZonesCount > 1 ->
    1;
remaining_zones_count(Pid, _ZonesCount, _MaxZonesPerDrone) ->
    logger:warning("!!! drone ~p can't get zones", [Pid]),
    0.

monitor_drone(Pid, ZoneAssignment) ->
    case maps:find(Pid, ZoneAssignment) of
        {ok, {MRef, _Zones}} -> MRef;
        error -> erlang:monitor(process, Pid)
    end.
