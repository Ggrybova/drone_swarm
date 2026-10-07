-module(drone_swarm_app).
-behaviour(application).

-export([start/2, stop/1]).

-define(HTTP_LISTENER, drone_swarm_http).
-define(DEF_HTTP_PORT, 8080).

start(_StartType, _StartArgs) ->
    {ok, _Pid} = Res = drone_swarm_sup:start_link(),
    {ok, _} = start_http(),
    Res.

stop(_State) ->
    ok = stop_http(),
    ok.

-spec start_http() -> {ok, pid()} | {error, term()}.
start_http() ->
    Port = application:get_env(drone_swarm, http_port, ?DEF_HTTP_PORT),
    TransOpts = [{port, Port}],
    Routes = [
        {'_', [
            {"/", cowboy_static, {priv_file, drone_swarm, "static/index.html"}},
            {"/static/[...]", cowboy_static, {priv_dir, drone_swarm, "static"}},
            {"/ws", drone_swarm_ws_handler, []}
        ]}
    ],
    Dispatch = cowboy_router:compile(Routes),
    ProtoOpts = #{env => #{dispatch => Dispatch}},
    cowboy:start_clear(?HTTP_LISTENER, TransOpts, ProtoOpts).

-spec stop_http() -> ok | {error, term()}.
stop_http() ->
    cowboy:stop_listener(?HTTP_LISTENER).
