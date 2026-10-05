-module(drone_swarm_motion_api).

%% API
-export([
    init_pos/2,
    move/4,
    pos_to_zone/2
]).

-ifdef(TEST).
-export([
    get_max_cell/2,
    get_adjacent_cells/2,
    check_cell/3
]).
-endif.

init_pos({A, B} = _CurrZone, {BlockWidth, BlockLength}) ->
    {A * BlockWidth, B * BlockLength}.

move(CurrPos, Zones, BlockSize, GridSize) ->
    MaxCell = get_max_cell(BlockSize, GridSize),
    PotentialPositions = get_adjacent_cells(CurrPos, MaxCell),
    case internal_move(PotentialPositions, Zones, BlockSize, GridSize) of
        {ok, NewPos} ->
            NewPos;
        error ->
            CurrPos
    end.

%% internal
get_adjacent_cells({X, Y}, {MaxX, MaxY}) ->
    [{X + A, Y + B} || {A, B} <- [{-1, 0}, {0, -1}, {1, 0}, {0, 1}],
        X + A >= 0, X + A =< MaxX,
        Y + B >= 0, Y + B =< MaxY
    ].

internal_move([], _Zones, _BlockSize, _GridSize) ->
    error;
internal_move(Positions, Zones, BlockSize, GridSize) ->
    NewPos = lists:nth(rand:uniform(length(Positions)), Positions),
    case check_cell(NewPos, Zones, BlockSize) of
        true ->
            {ok, NewPos};
        false ->
            internal_move(Positions -- [NewPos], Zones, BlockSize, GridSize)
    end.

get_max_cell({BlockWidth, BlockLength}, {GridWidth, GridLength}) ->
    {BlockWidth * GridWidth, BlockLength * GridLength}.

check_cell({X, Y} = _NewPos, Zones, {BlockWidth, BlockLength} = BlockSize) ->
    lists:any(
        fun(Zone) ->
            {X0, Y0} = _Min = init_pos(Zone, BlockSize),
            {X1, Y1} = _Max = {X0 + BlockWidth - 1, Y0 + BlockLength - 1},
            X >= X0 andalso X =< X1 andalso Y >= Y0 andalso Y =< Y1
        end, Zones
    ).

pos_to_zone({X, Y}, {BlockWidth, BlockLength}) ->
    {X div BlockWidth, Y div BlockLength}.
