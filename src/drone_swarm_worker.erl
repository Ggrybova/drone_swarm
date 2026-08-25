-module(drone_swarm_worker).
-behaviour(gen_statem).

%% API
-export([start_link/0]).
-export([init/1, callback_mode/0, terminate/3]).
-export([idle/3, active/3, charging/3]).

-define(BATTERY_LOW_TIMEOUT, 15000).
-define(CHARGING_TIME, 5000).
-define(INIT_DELAY_MAX, 5000).

-type zone() :: drone_swarm_zone_grid:zone().

-record(drone_swarm_worker_state, {
    position :: {integer(), integer()} | undefined,
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
    Delay = rand:uniform(?INIT_DELAY_MAX),
    gen_statem:cast(drone_swarm_chaos_monkey, {init_drone, self()}),
    {ok, idle, #drone_swarm_worker_state{}, [{{timeout, get_drone}, Delay, get_drone}]}.

%% @private
callback_mode() ->
    state_functions.

%% @private
idle({timeout, get_drone}, get_drone, _State) ->
    gen_statem:cast(drone_swarm_coordinator, {get_drone, self()}),
    keep_state_and_data;
idle(cast, {assign_zones, Zones}, State) ->
    %%    тут треба вираховувати новий рух дрону враховуючи приасайнені зони
    NewState = State#drone_swarm_worker_state{zones = Zones},
    Actions = [{{timeout, battery_low}, ?BATTERY_LOW_TIMEOUT, battery_low}],
    logger:info(" - ~p  assign_zones: ~p", [self(), Zones]),
    {next_state, active, NewState, Actions}.
active(cast, {assign_zones, Zones}, State) ->
    %%    тут треба вираховувати новий рух дрону враховуючи приасайнені зони
    NewState = State#drone_swarm_worker_state{zones = Zones},
    logger:info(" - ~p  assign_zones: ~p", [self(), Zones]),
    {next_state, active, NewState};
active(cast, {unassign_zones, Zones}, #drone_swarm_worker_state{zones = CurrZones} = State) ->
    UpdatedZones = CurrZones -- Zones,
    logger:info(" - ~p  unassign_zones: ~p", [self(), Zones]),
    %%    тут треба вираховувати новий рух дрону враховуючи приасайнені зони
    NewState = State#drone_swarm_worker_state{zones = UpdatedZones},
    {next_state, active, NewState};
active({timeout, battery_low}, battery_low, #drone_swarm_worker_state{} = State) ->
    gen_statem:cast(drone_swarm_coordinator, {battery_low, self()}),
    ChargingActions = [{{timeout, charging_done}, ?CHARGING_TIME, charging_done}],
    logger:info(" - ~p   battery_low", [self()]),
    {next_state, charging, State, ChargingActions}.
charging({timeout, charging_done}, charging_done, _State) ->
    gen_statem:cast(drone_swarm_coordinator, {get_drone, self()}),
    logger:info(" - ~p   charging_done", [self()]),
    {next_state, idle, #drone_swarm_worker_state{}};
charging(cast, {assign_zones, Zones}, _State) ->
    logger:info(" - ~p   assign_zones - zones_declined(~p)", [self(), Zones]),
    %% дрон вже сам перейшов у charging, а координатор ще не знав про це,
    %% коли надсилав assign_zones — відхиляємо, координатор поверне зони в пул
    gen_statem:cast(drone_swarm_coordinator, {zones_declined, self(), Zones}),
    keep_state_and_data.

%% @private
terminate(_Reason, _StateName, #drone_swarm_worker_state{} = _State) ->
    ok.
