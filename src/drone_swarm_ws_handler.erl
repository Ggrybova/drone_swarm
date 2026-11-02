-module(drone_swarm_ws_handler).
-behaviour(cowboy_websocket).

%% API
-export([
    init/2,
    websocket_init/1,
    websocket_handle/2,
    websocket_info/2
]).

init(Req, State) ->
    {cowboy_websocket, Req, State}.

websocket_init(State) ->
    ok = drone_swarm_view:subscribe(self()),
    {[], State}.

websocket_handle(_Frame, State) ->
    {[], State}.

websocket_info({drone_swarm_view, Json}, State) ->
    {[{text, Json}], State};
websocket_info(_Info, State) ->
    {[], State}.
