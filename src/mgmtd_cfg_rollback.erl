%%%-------------------------------------------------------------------
%%% @doc Numbered rollback files for committed configuration.
%%%
%%% `rollback.0` is a disk copy of the currently committed tree (not
%%% listed). `rollback.1` is the previous commit, and so on. Files live
%%% in `<db_location>/rollback/` and are backend-agnostic.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_cfg_rollback).

-include("mgmtd_schema.hrl").

-export([init/2, rotate_after_commit/0,
         list/0, show/1, read/1,
         same_as_running/1]).

-define(META_COUNT, rollback_count).
-define(VSN, 1).

-spec init(file:filename(), non_neg_integer()) -> ok | {error, term()}.
init(DbLocation, Count) when is_integer(Count), Count >= 0 ->
    true = ets:insert(mgmtd_meta, {?META_COUNT, Count}),
    case Count > 0 of
        true ->
            Dir = filename:join(DbLocation, "rollback"),
            case filelib:ensure_dir(filename:join(Dir, "dummy")) of
                ok ->
                    ok;
                {error, Reason} ->
                    {error, {rollback_dir, Dir, Reason}}
            end;
        false ->
            ok
    end.

-spec rotate_after_commit() -> ok | {error, term()}.
rotate_after_commit() ->
    case count() of
        N when N =< 0 ->
            ok;
        Count ->
            case current_rows() of
                {error, _} = Err ->
                    Err;
                {ok, Rows} ->
                    case shift(Count) of
                        ok ->
                            write_zero(Rows);
                        {error, _} = Err ->
                            Err
                    end
            end
    end.

-spec list() -> [{pos_integer(), map()}].
list() ->
    try count() of
        Count when Count =< 1 ->
            [];
        Count ->
            lists:filtermap(
              fun(N) ->
                      case read_meta(N) of
                          {ok, Meta} ->
                              {true, {N, Meta}};
                          {error, _} ->
                              false
                      end
              end, lists:seq(1, Count - 1))
    catch
        _:_ ->
            []
    end.

-spec show(non_neg_integer()) -> {ok, list()} | {error, term()}.
show(Index) when is_integer(Index), Index >= 0 ->
    case read(Index) of
        {ok, Rows} ->
            {ok, mgmtd_cfg_db:simplify_tree(mgmtd_cfg_db:cfg_list_to_tree(Rows))};
        {error, _} = Err ->
            Err
    end.

-spec read(non_neg_integer()) -> {ok, [#cfg{}]} | {error, term()}.
read(0) ->
    try
        case read_file(0) of
            {ok, #{rows := Rows}} ->
                {ok, Rows};
            {error, {unknown_rollback, 0}} ->
                current_rows();
            {error, _} = Err ->
                Err
        end
    catch
        error:db_not_initialized ->
            {error, db_not_initialized}
    end;
read(Index) when is_integer(Index), Index > 0 ->
    case count() of
        0 ->
            {error, {rollback_disabled, Index}};
        Count when Index >= Count ->
            {error, {unknown_rollback, Index}};
        _ ->
            try read_file(Index) of
                {ok, #{rows := Rows}} ->
                    {ok, Rows};
                {error, _} = Err ->
                    Err
            catch
                error:db_not_initialized ->
                    {error, db_not_initialized}
            end
    end.

-spec same_as_running([#cfg{}]) -> boolean().
same_as_running(Rows) ->
    case current_rows() of
        {ok, Current} ->
            normalize(Rows) =:= normalize(Current);
        {error, _} ->
            false
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

count() ->
    case ets:info(mgmtd_meta) of
        undefined ->
            0;
        _ ->
            case ets:lookup(mgmtd_meta, ?META_COUNT) of
                [{_, N}] when is_integer(N), N >= 0 ->
                    N;
                _ ->
                    0
            end
    end.

dir() ->
    case ets:lookup(mgmtd_meta, db_location) of
        [{_, Loc}] when is_list(Loc); is_binary(Loc) ->
            filename:join(Loc, "rollback");
        _ ->
            error(db_not_initialized)
    end.

file_path(Index) ->
    filename:join(dir(), "rollback." ++ integer_to_list(Index)).

current_rows() ->
    try
        {ok, mgmtd_cfg_db:match_object(
               #cfg{_ = mgmtd_schema:ets_pat('_')})}
    catch
        error:db_not_initialized ->
            {error, db_not_initialized};
        error:Reason ->
            {error, Reason}
    end.

shift(Count) when Count =< 1 ->
    ok;
shift(Count) ->
    _ = file:delete(file_path(Count - 1)),
    shift_from(Count - 2).

shift_from(K) when K < 0 ->
    ok;
shift_from(K) ->
    Src = file_path(K),
    Dst = file_path(K + 1),
    case filelib:is_regular(Src) of
        true ->
            _ = file:delete(Dst),
            case file:rename(Src, Dst) of
                ok ->
                    shift_from(K - 1);
                {error, Reason} ->
                    {error, {rename, Src, Reason}}
            end;
        false ->
            shift_from(K - 1)
    end.

write_zero(Rows) ->
    Term = {mgmtd_rollback, ?VSN,
            #{time => erlang:system_time(second)},
            [row_to_map(R) || R <- lists:keysort(#cfg.path, Rows)]},
    write_consult(file_path(0), Term).

write_consult(File, Term) ->
    ok = filelib:ensure_dir(File),
    IoData = mgmtd_cfg_db_sys_config:format_consult(Term),
    Tmp = File ++ ".tmp",
    case file:write_file(Tmp, IoData) of
        ok ->
            case file:consult(Tmp) of
                {ok, [Read]} when Read =:= Term ->
                    case file:rename(Tmp, File) of
                        ok ->
                            ok;
                        {error, Reason} ->
                            _ = file:delete(Tmp),
                            {error, {rename, Reason}}
                    end;
                {ok, Other} ->
                    _ = file:delete(Tmp),
                    {error, {consult_mismatch, Other}};
                {error, Reason} ->
                    _ = file:delete(Tmp),
                    {error, {consult, Tmp, Reason}}
            end;
        {error, Reason} ->
            {error, {write, Reason}}
    end.

read_meta(Index) ->
    case read_file(Index) of
        {ok, #{time := Time}} ->
            {ok, #{time => Time}};
        {error, _} = Err ->
            Err
    end.

read_file(Index) ->
    File = file_path(Index),
    case filelib:is_regular(File) of
        false ->
            {error, {unknown_rollback, Index}};
        true ->
            case file:consult(File) of
                {ok, [{mgmtd_rollback, ?VSN, Meta, Maps}]}
                  when is_map(Meta), is_list(Maps) ->
                    {ok, #{time => maps:get(time, Meta, undefined),
                           rows => [map_to_row(M) || M <- Maps]}};
                {ok, Other} ->
                    {error, {invalid_rollback, File, Other}};
                {error, Reason} ->
                    {error, {consult, File, Reason}}
            end
    end.

row_to_map(#cfg{path = Path, name = Name, node_type = Type, value = Value}) ->
    #{path => Path, name => Name, node_type => Type, value => Value}.

map_to_row(#{path := Path, node_type := Type} = M) ->
    Name = maps:get(name, M,
                    case Path of
                        [] -> [];
                        _ -> lists:last(Path)
                    end),
    #cfg{path = Path,
         name = Name,
         node_type = Type,
         value = maps:get(value, M, undefined)}.

normalize(Rows) ->
    lists:sort([{P, T, V} || #cfg{path = P, node_type = T, value = V} <- Rows]).
