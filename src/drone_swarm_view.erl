-module(drone_swarm_view).
-behaviour(gen_server).

-export([start_link/0]).
-export([update/4, subscribe/1, snapshot/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).
-define(TICK, 200).        %% як часто розсилати знімок, мс
-define(DEAD_TTL, 2000).   %% скільки показувати загиблого дрона, мс

-include("drone_swarm.hrl").

-type pos() :: {integer(), integer()} | undefined.
-type zone() :: drone_swarm_zone_grid_api:zone().

-record(drone, {
    mref :: reference(),
    state :: atom(),
    pos :: pos(),
    zones :: [zone()]
}).

-record(state, {
    grid_dim :: {pos_integer(), pos_integer()},
    block_size :: {pos_integer(), pos_integer()},
    drones = #{} :: #{pid() => #drone{}},
    dead = #{} :: #{pid() => {integer(), pos()}},   %% pid => {час смерті, остання позиція}
    subscribers = #{} :: #{pid() => reference()},
    dirty = false :: boolean()
}).

-include_lib("kernel/include/logger.hrl").

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec update(pid(), atom(), pos() | null, [zone()]) -> ok.
update(Pid, StateName, Pos, Zones) ->
    gen_server:cast(?SERVER, {update, Pid, StateName, Pos, Zones}).

-spec subscribe(pid()) -> ok.
subscribe(Pid) ->
    gen_server:cast(?SERVER, {subscribe, Pid}).

-spec snapshot() -> map().
snapshot() ->
    gen_server:call(?SERVER, snapshot).

init([]) ->
    GridDim = application:get_env(drone_swarm, grid_dim, ?DEF_GRID_DIM),
    BlockSize = application:get_env(drone_swarm, block_size, ?DEF_BLOCK_SIZE),
    State = #state{
        grid_dim = GridDim,
        block_size = BlockSize
    },
    erlang:send_after(?TICK, self(), tick),
    {ok, State}.

handle_call(snapshot, _From, State) ->
    {reply, to_map(State), State};
handle_call(Request, From, State) ->
    logger:info(" ERROR~nRequest: ~p,~nFrom: ~p,~nState: ~p,~n", [Request, From, State]),
    {reply, {error, unknown_call}, State}.

handle_cast({update, Pid, StateName, Pos, Zones}, #state{drones = Drones} = State) ->
    MRef = case maps:find(Pid, Drones) of
               {ok, #drone{mref = Ref}} -> Ref;
               error -> erlang:monitor(process, Pid)
           end,
    Drone = #drone{mref = MRef, state = StateName, pos = Pos, zones = zones(Zones)},
    {noreply, State#state{drones = Drones#{Pid => Drone}, dirty = true}};
handle_cast({subscribe, Pid}, #state{subscribers = Subs} = State) ->
    MRef = erlang:monitor(process, Pid),
    Pid ! {drone_swarm_view, encode(State)},
    {noreply, State#state{subscribers = Subs#{Pid => MRef}}};
handle_cast(Request, #state{} = State) ->
    logger:info(" ERROR~nRequest: ~p,~nState: ~p,~n", [Request, State]),
    {noreply, State}.

handle_info(tick, State) ->
    erlang:send_after(?TICK, self(), tick),
    {noreply, maybe_broadcast(expire_dead(State))};
handle_info({'DOWN', _MRef, process, Pid, _Reason}, #state{drones = Drones} = State)
    when is_map_key(Pid, Drones) ->
    #drone{pos = Pos} = maps:get(Pid, Drones),
    Now = erlang:monotonic_time(millisecond),
    {noreply, State#state{
        drones = maps:remove(Pid, Drones),
        dead = (State#state.dead)#{Pid => {Now, Pos}},
        dirty = true
    }};
handle_info({'DOWN', _MRef, process, Pid, _Reason}, #state{subscribers = Subs} = State)
    when is_map_key(Pid, Subs) ->
    {noreply, State#state{subscribers = maps:remove(Pid, Subs)}};
handle_info(_Info, #state{} = State) ->
    {noreply, State}.

terminate(_Reason, #state{} = _State) ->
    ok.

code_change(_OldVsn, #state{} = State, _Extra) ->
    {ok, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================
expire_dead(#state{dead = Dead} = State) ->
    Now = erlang:monotonic_time(millisecond),
    Recent = maps:filter(
        fun(_Pid, {DiedAt, _Pos}) ->
            Now - DiedAt < ?DEAD_TTL
        end, Dead),
    case map_size(Recent) =:= map_size(Dead) of
        true -> State;
        false -> State#state{dead = Recent, dirty = true}
    end.

maybe_broadcast(#state{dirty = false} = State) ->
    State;
maybe_broadcast(#state{subscribers = Subs} = State) ->
    Msg = {drone_swarm_view, encode(State)},
    maps:foreach(fun(Pid, _MRef) -> Pid ! Msg end, Subs),
    State#state{dirty = false}.

encode(State) ->
    iolist_to_binary(json:encode(to_map(State))).

to_map(#state{grid_dim = {GW, GL}, block_size = {BW, BL}, drones = Drones, dead = Dead}) ->
    #{
        grid => [GW, GL],
        block => [BW, BL],
        drones => [drone_to_map(Pid, D) || Pid := D <- Drones],
        dead => [#{id => pid_bin(Pid), pos => pos_list(Pos)} || Pid := {_, Pos} <- Dead]
    }.

drone_to_map(Pid, #drone{state = StateName, pos = Pos, zones = Zones}) ->
    #{
        id => pid_bin(Pid),
        state => StateName,
        pos => pos_list(Pos),
        zones => [[X, Y] || {X, Y} <- Zones]
    }.

%%zones(undefined) -> [];
zones(Zones) when is_list(Zones) -> Zones.

pos_list(null) -> null;
pos_list({X, Y}) -> [X, Y].

pid_bin(Pid) ->
    list_to_binary(pid_to_list(Pid)).