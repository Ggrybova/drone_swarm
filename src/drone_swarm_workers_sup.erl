-module(drone_swarm_workers_sup).
-behaviour(supervisor).

-export([start_link/1, init/1]).

start_link(NumDrones) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [NumDrones]).

init([NumDrones]) ->
    Children = [
        #{
            id       => {drone_swarm_worker, Num},
            start    => {drone_swarm_worker, start_link, []},
            restart  => permanent,
            shutdown => 5000,
            type     => worker,
            modules  => [drone_swarm_worker]
        }
        || Num <- lists:seq(1, NumDrones)
    ],

    {ok, {#{strategy => one_for_one,
        intensity => 5,
        period => 30},
        Children}
    }.
