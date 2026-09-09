-module(drone_swarm_chaos_monkey).

-behaviour(gen_server).

-export([start_link/0, kill_coordinator/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
    code_change/3]).

-define(SERVER, ?MODULE).
-define(KILL_INTERVAL, 7000).

-record(drone_swarm_chaos_monkey_state, {
    kill_interval :: integer(),
    drones = [] :: [pid()] %% список дронів
}).

%%%===================================================================
%%% Spawning and gen_server implementation
%%%===================================================================
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

kill_coordinator() ->
    case whereis(drone_swarm_coordinator) of
        undefined ->
            {error, not_running};
        Pid ->
            logger:info(" = KILL COORDINATOR = ~p", [Pid]),
            exit(Pid, kill),
            ok
    end.

init([]) ->
    KillInterval = application:get_env(drone_swarm, chaos_interval, ?KILL_INTERVAL),
    _ = erlang:send_after(KillInterval, self(), kill_drone),
    {ok, #drone_swarm_chaos_monkey_state{kill_interval = KillInterval}}.

handle_call(_Request, _From, #drone_swarm_chaos_monkey_state{} = State) ->
    {reply, ok, State}.

handle_cast({init_drone, Pid}, #drone_swarm_chaos_monkey_state{drones = Drones} = State) ->
    {noreply, State#drone_swarm_chaos_monkey_state{drones = [Pid | Drones]}};
handle_cast(_Request, #drone_swarm_chaos_monkey_state{} = State) ->
    {noreply, State}.

handle_info(kill_drone, #drone_swarm_chaos_monkey_state{drones = [_ | _] = Drones,
    kill_interval = KillInterval} = State) ->
    DronePid = lists:nth(rand:uniform(length(Drones)), Drones),
    true = exit(DronePid, kill),
    X = erlang:send_after(KillInterval, self(), kill_drone),
    logger:debug(" = KILL = ~p, ~p", [DronePid, X]),
    {noreply, State#drone_swarm_chaos_monkey_state{drones = lists:delete(DronePid, Drones)}};
handle_info(_Info, #drone_swarm_chaos_monkey_state{} = State) ->
    {noreply, State}.

terminate(_Reason, #drone_swarm_chaos_monkey_state{} = _State) ->
    ok.

code_change(_OldVsn, #drone_swarm_chaos_monkey_state{} = State, _Extra) ->
    {ok, State}.
