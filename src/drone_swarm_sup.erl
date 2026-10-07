-module(drone_swarm_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(DEF_NUM_DRONES, 5).
-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 3,
        period => 10
    },
    NumDrones = application:get_env(drone_swarm, num_drones, ?DEF_NUM_DRONES),
    ChildSpecs = [
        #{
            id          => drone_swarm_coordinator,
            start       => {drone_swarm_coordinator, start_link, [NumDrones]},
            restart     => permanent,
            shutdown    => 5000,
            type        => worker
        },
        #{
            id          => drone_swarm_chaos_monkey,
            start       => {drone_swarm_chaos_monkey, start_link, []},
            restart     => permanent,
            shutdown    => 5000,
            type        => worker
        },
        #{
            id          => drone_swarm_view,
            start       => {drone_swarm_view, start_link, []},
            restart     => permanent,
            shutdown    => 5000,
            type        => worker
        },
        #{
            id          => drone_swarm_workers_sup,
            start       => {drone_swarm_workers_sup, start_link, [NumDrones]},
            restart     => permanent,
            shutdown    => infinity,
            type        => supervisor
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
