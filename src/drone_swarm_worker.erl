-module(drone_swarm_worker).
-behaviour(gen_statem).

%% API
-export([start_link/0]).
-export([init/1, callback_mode/0, terminate/3]).
-export([idle/3, active/3, charging/3]).

-ifdef(TEST).
-define(INIT_DELAY_MAX, 800).
-define(CHARGING_TIME, 2000).
-define(BATTERY_LOW_TIMEOUT, 3000).
-else.
-define(INIT_DELAY_MAX, 5000).
-define(CHARGING_TIME, 5000).
-define(BATTERY_LOW_TIMEOUT, 15000).
-endif.

-define(MOTION_TIMEOUT, 1000).

-type zone() :: drone_swarm_zone_grid_api:zone().

-include("drone_swarm.hrl").

-record(state, {
    block_size :: {integer(), integer()},
    grid_size :: {integer(), integer()},
    position :: {integer(), integer()} | undefined,
    drone_location :: {integer(), integer()} | undefined,
    motion_timeout = ?MOTION_TIMEOUT :: integer(),
    zones :: [zone()] | undefined
}).

%%%===================================================================
%%% API
%%%===================================================================
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_statem:start_link(?MODULE, [], []).

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================
%% @private
init([]) ->
    BlockSize = application:get_env(drone_swarm, block_size, ?DEF_BLOCK_SIZE),
    GridDim = application:get_env(drone_swarm, grid_dim, ?DEF_GRID_DIM),
    Delay = rand:uniform(?INIT_DELAY_MAX),
    MotionTimeout = application:get_env(drone_swarm, motion_timeout, ?MOTION_TIMEOUT),
    gen_statem:cast(drone_swarm_chaos_monkey, {init_drone, self()}),
    notify_view(idle), %% створився дрон, треба поставити монітор
    State = #state{
        block_size = BlockSize,
        grid_size = GridDim,
        motion_timeout = MotionTimeout
    },
    Actions = [
        {{timeout, get_drone}, Delay, get_drone},
        {{timeout, move}, MotionTimeout, move}
    ],
    {ok, idle, State, Actions}.

%% @private
callback_mode() ->
    state_functions.

%% @private
idle({timeout, get_drone}, get_drone, _State) ->
    gen_statem:cast(drone_swarm_coordinator, {get_drone, self()}),
    keep_state_and_data;
idle(cast, {assign_zones, [Zone | _] = Zones},
    #state{block_size = BlockSize} = State) ->
    InitPos = drone_swarm_motion_api:init_pos(Zone, BlockSize),
    DroneLocation = drone_swarm_motion_api:pos_to_zone(InitPos, BlockSize),
    gen_statem:cast(drone_swarm_coordinator, {drone_location, self(), DroneLocation}),
    notify_view(active, InitPos, Zones), %% вперше отримав зони
    NewState = State#state{
        position = InitPos,
        drone_location = DroneLocation,
        zones = Zones
    },
    Actions = [{{timeout, battery_low}, ?BATTERY_LOW_TIMEOUT, battery_low}],
    logger:info(" - ~p  pos ~p assign_zones: ~p", [self(), InitPos, Zones]),
    {next_state, active, NewState, Actions};
idle(cast, {assign_zones, []}, _State) ->
    logger:info(" - !!!!!! IDLE ~p  assign NO zones", [self()]),
    keep_state_and_data;
idle(cast, {request_zones, Coordinator}, #state{zones = Zones}) ->
    report_zones(Coordinator, Zones),
    keep_state_and_data;
idle({timeout, move}, move, #state{motion_timeout = Timeout} = _State) ->
%%    logger:info(" - !!! move idle ~p", [self()]),
    notify_view(idle), %% тимчасово
    reschedule_move(Timeout).

active(cast, {assign_zones, Zones}, #state{position = Pos} = State) ->
    notify_view(active, Pos, Zones), %% взяв додаткові зони
    NewState = State#state{zones = Zones},
    {next_state, active, NewState};
active(cast, {unassign_zones, Zones}, #state{position = Pos, zones = CurrZones} = State) ->
    UpdatedZones = CurrZones -- Zones,
    notify_view(active, Pos, UpdatedZones), %% віддав деякі зони
    NewState = State#state{zones = UpdatedZones},
    {next_state, active, NewState};
active({timeout, battery_low}, battery_low, #state{grid_size = GridSize,
    block_size = BlockSize, motion_timeout = Timeout} = _State) ->
    gen_statem:cast(drone_swarm_coordinator, {battery_low, self()}),
    notify_view(charging), %% пішов заряджатись
    ChargingActions = [{{timeout, charging_done}, ?CHARGING_TIME, charging_done}],
%%    logger:info(" - ~p   battery_low", [self()]),
    CleanState = #state{
        grid_size = GridSize,
        block_size = BlockSize,
        motion_timeout = Timeout
    },
    {next_state, charging, CleanState, ChargingActions};
active(cast, {request_zones, Coordinator}, #state{zones = Zones}) ->
    report_zones(Coordinator, Zones),
    keep_state_and_data;
active({timeout, move}, move, #state{zones = Zones,
    position = CurrPos, block_size = BlockSize, motion_timeout = Timeout,
    grid_size = GridSize, drone_location = DroneLocation} = State) ->
    NewPos = drone_swarm_motion_api:move(CurrPos, Zones, BlockSize, GridSize),
    notify_view(active, NewPos, Zones), %% рух дрона
    NewDroneLocation = drone_swarm_motion_api:pos_to_zone(NewPos, BlockSize),
    NewState = case DroneLocation =:= NewDroneLocation of
        true ->
            State#state{position = NewPos};
        false ->
            gen_statem:cast(drone_swarm_coordinator, {drone_location, self(), NewDroneLocation}),
            State#state{
                position = NewPos,
                drone_location = NewDroneLocation
            }
    end,
%%    logger:info(" - ~p  MOVE: ~p -> ~p", [self(), CurrPos, NewPos]),
    {next_state, active, NewState, [{{timeout, move}, Timeout, move}]}.

charging({timeout, charging_done}, charging_done, State) ->
    gen_statem:cast(drone_swarm_coordinator, {get_drone, self()}),
%%    logger:info(" - ~p   charging_done", [self()]),
    notify_view(idle),
    {next_state, idle, State};
charging(cast, {assign_zones, Zones}, _State) ->
%%    logger:info(" - ~p   assign_zones - zones_declined(~p)", [self(), Zones]),
    %% дрон вже сам перейшов у charging, а координатор ще не знав про це,
    %% коли надсилав assign_zones — відхиляємо, координатор поверне зони в пул
    gen_statem:cast(drone_swarm_coordinator, {zones_declined, self(), Zones}),
    keep_state_and_data;
charging(cast, {request_zones, Coordinator}, #state{zones = Zones}) ->
    report_zones(Coordinator, Zones),
    keep_state_and_data;
charging({timeout, move}, move, #state{motion_timeout = Timeout} = _State) ->
%%    logger:info(" - !!! move charging ~p", [self()]),
    notify_view(charging), %% тимчасово
    reschedule_move(Timeout).

%% @private
terminate(_Reason, _StateName, #state{} = _State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

report_zones(Coordinator, undefined) ->
    gen_statem:cast(Coordinator, {zones_report, self(), []});
report_zones(Coordinator, Zones) when is_list(Zones) ->
    gen_statem:cast(Coordinator, {zones_report, self(), Zones}).

reschedule_move(Timeout) ->
    {keep_state_and_data, [{{timeout, move}, Timeout, move}]}.

notify_view(StateName) ->
    notify_view(StateName, null, []).
notify_view(StateName, Pos, Zones) ->
    drone_swarm_view:update(self(), StateName, Pos, Zones).
