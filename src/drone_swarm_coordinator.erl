-module(drone_swarm_coordinator).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEF_GRID_DIM, {3, 3}).

-include_lib("kernel/include/logger.hrl").

-type zone() :: drone_swarm_zone_grid:zone().

-record(drone_swarm_coordinator_state, {
    num_drones :: integer(), %% загальна кількість дронів
    num_zones :: integer(), %% загальна кількість зон
    assigned_zones :: [zone()], %% список закріплених зон
    unassigned_zones :: [zone()], %% список пустих зон
    max_zones_per_drone :: integer(), %% макс.початкова кількість зон на дрона
    zone_assignments = #{} :: map()  %% #{drone_pid::pid() => {ref(), [zone()]}}
                                     %% звʼязка дрон - зони
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

-spec start_link(NumDrones :: pos_integer()) -> {ok, pid()} | {error, term()}.
start_link(NumDrones) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [NumDrones], []).

init([NumDrones]) ->
    {GridWidth, GridLength} = application:get_env(drone_swarm, grid_dim, ?DEF_GRID_DIM),
    NumZones = GridWidth * GridLength,
    MaxZonesPerDrone = round(NumZones / NumDrones),
    Zones = [{ZoneId div GridLength, ZoneId rem GridLength} ||
        ZoneId <- lists:seq(0, NumZones - 1)],
    {ok, #drone_swarm_coordinator_state{
        num_drones = NumDrones,
        num_zones = NumZones,
        assigned_zones = [],
        unassigned_zones = Zones,
        max_zones_per_drone = MaxZonesPerDrone
    }}.

handle_call(_Request, _From, #drone_swarm_coordinator_state{} = State) ->
    {reply, ok, State}.

handle_cast({get_drone, Pid}, #drone_swarm_coordinator_state{zone_assignments = ZoneAssignment,
    assigned_zones = AssignedZoneIds, unassigned_zones = [_|_] = UnassignedZoneIds} = State) ->
    MRef = monitor_drone(Pid, ZoneAssignment),
    ConnectedZones = drone_swarm_zone_grid:select_connected_zones(null, UnassignedZoneIds),
    Rest = UnassignedZoneIds -- ConnectedZones,
    Rest =/= [] andalso logger:info("!!! ConnectedZones: ~p, Rest: ~p", [ConnectedZones, Rest]),
    gen_statem:cast(Pid, {assign_zones, ConnectedZones}),
    logger:info(" *  ASIGN  ~p -> ~p", [Pid, ConnectedZones]),
    NewState = State#drone_swarm_coordinator_state{
        assigned_zones = ConnectedZones ++ AssignedZoneIds,
        unassigned_zones = Rest,
        zone_assignments = ZoneAssignment#{Pid => {MRef, ConnectedZones}}},
    {noreply, NewState};
handle_cast({get_drone, Pid}, #drone_swarm_coordinator_state{zone_assignments = ZoneAssignment,
    max_zones_per_drone = MaxZonesPerDrone} = State) ->
    MRef = monitor_drone(Pid, ZoneAssignment),
    NewZoneAssignment = rebalance_zones(Pid, MRef, MaxZonesPerDrone, ZoneAssignment),
    {noreply, State#drone_swarm_coordinator_state{zone_assignments = NewZoneAssignment}};
handle_cast({battery_low, Pid}, #drone_swarm_coordinator_state{zone_assignments = ZoneAssignment,
    assigned_zones = AssignedZoneIds, unassigned_zones = UnassignedZoneIds} = State) ->
    {MRef, EmptyZones} = maps:get(Pid, ZoneAssignment),
    logger:info("  * {batary_low, ~p}~n Ass-nt: ~p", [Pid, ZoneAssignment]),
    case reassign_zones(Pid, ZoneAssignment) of
        {ok, NewZoneAssignment} ->
            NewState = State#drone_swarm_coordinator_state{
                zone_assignments = NewZoneAssignment#{Pid => {MRef, []}}
            },
            {noreply, NewState};
        {notfound, NewZoneAssignment} ->
            AssignedZoneIds = State#drone_swarm_coordinator_state.assigned_zones,
            UnassignedZoneIds = State#drone_swarm_coordinator_state.unassigned_zones,
            logger:info("!!! {batary_low, ~p} ZONES NOTFOUND~n zones ~p -> unassigned", [Pid, EmptyZones]),
            NewState = State#drone_swarm_coordinator_state{
                zone_assignments = NewZoneAssignment#{Pid => {MRef, []}},
                assigned_zones = AssignedZoneIds -- EmptyZones,
                unassigned_zones = lists:usort(UnassignedZoneIds ++ EmptyZones)
            },
            {noreply, NewState}
    end;
handle_cast({zones_declined, Pid, Zones}, #drone_swarm_coordinator_state{
    zone_assignments = ZoneAssignment, assigned_zones = AssignedZoneIds,
    unassigned_zones = UnassignedZoneIds} = State) ->
    NewZoneAssignment = maps:without([Pid], ZoneAssignment),
    logger:info("!!! {zones_declined, ~p}: zones ~p -> unassigned", [Pid, Zones]),
    NewState = State#drone_swarm_coordinator_state{
        zone_assignments = NewZoneAssignment,
        assigned_zones = AssignedZoneIds -- Zones,
        unassigned_zones = lists:usort(UnassignedZoneIds ++ Zones)
    },
    {noreply, NewState};
handle_cast(_Request, #drone_swarm_coordinator_state{} = State) ->
    {noreply, State}.

handle_info({'DOWN', MRef, process, Pid, killed},
    #drone_swarm_coordinator_state{zone_assignments = ZoneAssignment} = State)
    when is_map_key(Pid, ZoneAssignment) ->
    {MRef, EmptyZones} = maps:get(Pid, ZoneAssignment),
    logger:info(" * ~p was KILLED EmptyZones: ~p~n", [Pid, EmptyZones]),
    case reassign_zones(Pid, ZoneAssignment) of
        {ok, NewZoneAssignment} ->
            NewState = State#drone_swarm_coordinator_state{zone_assignments = NewZoneAssignment},
            {noreply, NewState};
        {notfound, NewZoneAssignment} ->
            AssignedZoneIds = State#drone_swarm_coordinator_state.assigned_zones,
            UnassignedZoneIds = State#drone_swarm_coordinator_state.unassigned_zones,
            logger:info("!!! {killed, ~p} ZONES NOTFOUND~n zones ~p -> unassigned", [Pid, EmptyZones]),
            NewState = State#drone_swarm_coordinator_state{
                zone_assignments = NewZoneAssignment,
                assigned_zones = AssignedZoneIds -- EmptyZones,
                unassigned_zones = lists:usort(UnassignedZoneIds ++ EmptyZones)
            },
            {noreply, NewState}
    end;
handle_info({'DOWN', _MRef, process, Pid, killed}, #drone_swarm_coordinator_state{} = State) ->
    logger:info("!!!  ~p was KILLED ", [Pid]),
    {noreply, State};
handle_info(Info, #drone_swarm_coordinator_state{} = State) ->
    logger:info("!!!  ~p", [Info]),
    {noreply, State}.

terminate(_Reason, #drone_swarm_coordinator_state{} = _State) ->
    ok.

code_change(_OldVsn, #drone_swarm_coordinator_state{} = State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
reassign_zones(Pid, ZoneAssignment) ->
    {_, EmptyZones} = maps:get(Pid, ZoneAssignment),
    ZoneAssignment2 = maps:without([Pid], ZoneAssignment),
    ZoneAssignmentList = lists:sort(
        fun({_Key1, {_, List1}}, {_Key2, {_, List2}}) -> length(List1) =< length(List2) end,
        maps:to_list(ZoneAssignment2)
    ),
    case drone_swarm_zone_grid:find_adjacent_drone(EmptyZones, ZoneAssignmentList) of
        {ok, LeastLoadedDronePid} ->
            {MRef, Zones} = maps:get(LeastLoadedDronePid, ZoneAssignment2),
            NewZones = Zones ++ EmptyZones,
            gen_statem:cast(LeastLoadedDronePid, {assign_zones, NewZones}),
            NewZoneAssignment = ZoneAssignment2#{LeastLoadedDronePid => {MRef, NewZones}},
            {ok, NewZoneAssignment};
        undefined ->
            {notfound, ZoneAssignment2}
    end.

rebalance_zones(Pid, MRef1, MaxZonesPerDrone, ZoneAssignment) ->
    Fun = fun(Drone, {_Ref, Zones}, {_, MaxLength} = Acc) ->
        Length = length(Zones),
        case Length > MaxLength of
            true -> {Drone, Length};
            false -> Acc
        end
    end,
    {MostLoadedDronePid, ZonesCount} = maps:fold(Fun, {undefined, 0}, ZoneAssignment),
    {MRef2, ZoneList} = maps:get(MostLoadedDronePid, ZoneAssignment),
    RemainingZonesCount = if
        ZonesCount > MaxZonesPerDrone ->
            MaxZonesPerDrone;
        ZonesCount =:= MaxZonesPerDrone ->
            MaxZonesPerDrone - 1;
        ZonesCount > 1 ->
            1;
        true ->
            logger:warning("!!! drone ~p can't get zones", [Pid]),
            0
    end,
    ZonesToRemove = drone_swarm_zone_grid:select_connected_zones(RemainingZonesCount, ZoneList),
    ZonesToKeep = ZoneList -- ZonesToRemove,
    gen_statem:cast(MostLoadedDronePid, {unassign_zones, ZonesToRemove}),
    gen_statem:cast(Pid, {assign_zones, ZonesToRemove}),
    logger:info(" * RE ASIGN ~n       {~p - ~p}~n       {~p + ~p}",
        [MostLoadedDronePid, ZonesToRemove, Pid, ZonesToRemove]),
    ZoneAssignment#{
        Pid => {MRef1, ZonesToRemove},
        MostLoadedDronePid => {MRef2, ZonesToKeep}
    }.

monitor_drone(Pid, ZoneAssignment) ->
    case maps:find(Pid, ZoneAssignment) of
        {ok, {MRef, _Zones}} -> MRef;
        error -> erlang:monitor(process, Pid)
    end.
