%%%-------------------------------------------------------------------
%%% @author Sean Hinde <sean@Seans-MacBook.local>
%%% @copyright (C) 2019, Sean Hinde
%%% @doc Configuration session transaction handler
%%%
%%% @end
%%% Created : 18 Sep 2019 by Sean Hinde <sean@Seans-MacBook.local>
%%%-------------------------------------------------------------------
-module(mgmtd_cfg_txn).

-include("../include/mgmtd.hrl").
-include("mgmtd_schema.hrl").

-record(cfg_txn,
        {
         txn_id,
         ops = [],
         ets_copy,
         baseline :: ets:table() | undefined,
         replace = false :: boolean()
        }).

-type txn() :: #cfg_txn{}.

-export_type([txn/0]).

-export([new/0, exit_txn/1, get/2, get_stored/2, get_tree/2, get_tree/3, set/3, delete/2,
         move/3, list_keys/3, match_object/2, commit/1, rollback/2, will_change/1,
         tree/1, baseline_tree/1]).

new() ->
    TxnId = erlang:unique_integer(),
    Copy = mgmtd_cfg_db:copy_to_ets(),
    #cfg_txn{txn_id = TxnId,
             ets_copy = Copy,
             baseline = snapshot_ets(Copy)
            }.

exit_txn(#cfg_txn{ets_copy = EtsCopy, baseline = Baseline}) ->
    catch ets:delete(EtsCopy),
    catch ets:delete(Baseline),
    ok.

snapshot_ets(Src) ->
    Dst = ets:new(cfg_txn_base, [public, ordered_set, {keypos, #cfg.path}]),
    true = ets:insert(Dst, ets:tab2list(Src)),
    Dst.

%% Session working tree (after local edits).
tree(#cfg_txn{} = Txn) ->
    get_tree(Txn, []).

%% Snapshot of running taken when the session started.
baseline_tree(#cfg_txn{baseline = undefined}) ->
    [];
baseline_tree(#cfg_txn{baseline = Baseline}) ->
    get_tree_from({ets, Baseline}, []).

%% @doc commit the operations stored up in the configuration transaction.
%% Ops are recorded newest-first; apply oldest-first so a delete then
%% re-add of the same list item in one session lands as the re-add.
%% A rollback-loaded txn (`replace = true`) writes the whole ETS copy.
%%
%% Concurrent sessions may edit disjoint paths. If running has moved
%% under a path this session also changed, commit returns
%% `{error, {conflict, Path}}` and leaves the txn alive.
commit(#cfg_txn{replace = true} = Txn) ->
    case will_change(Txn) of
        false ->
            commit(Txn#cfg_txn{replace = false, ops = []});
        true ->
            case mgmtd_yang_xpath:validate_txn(Txn) of
                {error, _} = Err ->
                    Err;
                ok ->
                    commit_replace(Txn)
            end
    end;
commit(#cfg_txn{ops = Ops} = Txn) ->
    case mgmtd_yang_xpath:validate_txn(Txn) of
        {error, _} = Err ->
            Err;
        ok ->
            commit_ops(Txn, Ops)
    end.

commit_replace(#cfg_txn{ets_copy = Ets} = Txn) ->
    case check_commit_conflict(Txn) of
        {error, _} = Err ->
            Err;
        ok ->
            Rows = ets:tab2list(Ets),
            case mgmtd_cfg_db:transaction(fun() -> mgmtd_cfg_db:replace_all(Rows) end) of
                ok ->
                    ok = exit_txn(Txn),
                    {ok, new()};
                Err ->
                    Err
            end
    end.

-spec will_change(#cfg_txn{}) -> boolean().
will_change(#cfg_txn{replace = true, ets_copy = Ets}) ->
    not mgmtd_cfg_rollback:same_as_running(ets:tab2list(Ets));
will_change(#cfg_txn{ops = []}) ->
    false;
will_change(#cfg_txn{}) ->
    true.

-spec rollback(#cfg_txn{}, non_neg_integer()) -> {ok, #cfg_txn{}} | {error, term()}.
rollback(#cfg_txn{ets_copy = Ets} = Txn, Index) when is_integer(Index), Index >= 0 ->
    case mgmtd_cfg_rollback:read(Index) of
        {ok, Rows} ->
            true = ets:delete_all_objects(Ets),
            _ = [ets:insert(Ets, Row) || Row <- Rows],
            {ok, Txn#cfg_txn{replace = true, ops = []}};
        {error, _} = Err ->
            Err
    end.

commit_ops(#cfg_txn{} = Txn, Ops) ->
    case check_commit_conflict(Txn) of
        {error, _} = Err ->
            %% Leave the session alive so the user can discard or retry.
            Err;
        ok ->
            Fun = fun() ->
                          lists:foreach(fun({set, Path, Value}) ->
                                                mgmtd_cfg_db:insert_path_items(permanent, Path, Value);
                                           ({delete, Path}) ->
                                                mgmtd_cfg_db:delete_path_items(permanent, Path);
                                           ({move, Path, Where}) ->
                                                case mgmtd_cfg_db:move_item(permanent, Path, Where) of
                                                    {ok, _} ->
                                                        ok;
                                                    {error, Reason} ->
                                                        throw({error, Reason})
                                                end
                                        end, lists:reverse(Ops))
                  end,
            case mgmtd_cfg_db:transaction(Fun) of
                ok ->
                    ok = exit_txn(Txn),
                    {ok, new()};
                Err ->
                    Err
            end
    end.

%% Three-way check: baseline (at txn_new) vs running vs this session.
%% Disjoint remote edits are allowed. The same path changed to two
%% different values is a conflict. A full replace also conflicts when
%% running has moved at all, because it would clobber those commits.
-spec check_commit_conflict(#cfg_txn{}) -> ok | {error, {conflict, item_path()}}.
check_commit_conflict(#cfg_txn{baseline = undefined}) ->
    ok;
check_commit_conflict(#cfg_txn{ops = [], replace = false}) ->
    ok;
check_commit_conflict(#cfg_txn{ets_copy = Copy, baseline = Baseline,
                               ops = Ops, replace = Replace}) ->
    CopyMap = rows_to_map(ets:tab2list(Copy)),
    BaseMap = rows_to_map(ets:tab2list(Baseline)),
    RunMap = rows_to_map(
               mgmtd_cfg_db:match_object(
                 #cfg{_ = mgmtd_schema:ets_pat('_')})),
    case three_way_conflict(CopyMap, BaseMap, RunMap) of
        {error, _} = Err ->
            Err;
        ok ->
            case deleted_descendant_conflict(Ops, BaseMap, RunMap) of
                {error, _} = Err ->
                    Err;
                ok when Replace ->
                    case first_remote_change(BaseMap, RunMap) of
                        undefined ->
                            ok;
                        Path ->
                            {error, {conflict, Path}}
                    end;
                ok ->
                    ok
            end
    end.

rows_to_map(Rows) ->
    maps:from_list([{P, C} || #cfg{path = P} = C <- Rows]).

row(Map, Path) ->
    maps:get(Path, Map, none).

three_way_conflict(CopyMap, BaseMap, RunMap) ->
    Paths = lists:sort(maps:keys(maps:merge(CopyMap, BaseMap))),
    first_ok(
      fun(Path) ->
              Session = row(CopyMap, Path),
              Base = row(BaseMap, Path),
              case Session =:= Base of
                  true ->
                      ok;
                  false ->
                      Running = row(RunMap, Path),
                      if Running =:= Base -> ok;
                         Running =:= Session -> ok;
                         true -> {error, {conflict, Path}}
                      end
              end
      end, Paths).

%% Delete of an ancestor would drop running-only descendants (e.g. a
%% leaf another session added under the same list item). Use the
%% session's delete ops, not implicit parent cleanup in the ETS copy.
deleted_descendant_conflict(Ops, BaseMap, RunMap) ->
    Deleted = lists:usort(
                [mgmtd_cfg_db:schema_path_to_key(Path) || {delete, Path} <- Ops]),
    case Deleted of
        [] ->
            ok;
        _ ->
            Paths = lists:sort(maps:keys(RunMap)),
            first_ok(
              fun(Path) ->
                      case row(BaseMap, Path) =:= none andalso
                          under_deleted(Path, Deleted) of
                          true ->
                              {error, {conflict, Path}};
                          false ->
                              ok
                      end
              end, Paths)
    end.

under_deleted(Path, Deleted) ->
    lists:any(fun(Prefix) -> lists:prefix(Prefix, Path) end, Deleted).

first_remote_change(BaseMap, RunMap) ->
    Paths = lists:sort(maps:keys(maps:merge(BaseMap, RunMap))),
    first_undefined(
      fun(Path) ->
              case row(BaseMap, Path) =:= row(RunMap, Path) of
                  true -> undefined;
                  false -> Path
              end
      end, Paths).

first_ok(_Fun, []) ->
    ok;
first_ok(Fun, [P | Ps]) ->
    case Fun(P) of
        ok ->
            first_ok(Fun, Ps);
        {error, _} = Err ->
            Err
    end.

first_undefined(_Fun, []) ->
    undefined;
first_undefined(Fun, [P | Ps]) ->
    case Fun(P) of
        undefined ->
            first_undefined(Fun, Ps);
        Path ->
            Path
    end.

-spec get(#cfg_txn{}, item_path()) -> {ok, any()} | undefined.
get(#cfg_txn{ets_copy = Copy}, Path) ->
    case ets:lookup(Copy, Path) of
        [#cfg{value = Value}] ->
            {ok, Value};
        [] ->
            mgmtd_schema:get_default(Path)
    end.

%% Stored value only — no schema default. `undefined` txn reads committed DB.
-spec get_stored(txn() | undefined, item_path()) -> {ok, term()} | none.
get_stored(#cfg_txn{ets_copy = Copy}, Path) ->
    case ets:lookup(Copy, Path) of
        [#cfg{value = Value}] ->
            {ok, Value};
        [] ->
            none
    end;
get_stored(undefined, Path) ->
    case mgmtd_cfg_db:lookup(Path) of
        [#cfg{value = Value}] ->
            {ok, Value};
        _ ->
            none
    end;
get_stored(_, _) ->
    none.

%% Operational mode (no config txn) reads committed config from the
%% backend. There is no named ETS table `cfg` — that was leftover from
%% an earlier ETS-only store. Operational-data paths (`config = false`
%% with a host `data_callback`) are filled from the provider instead.
get_tree(Txn, Path) ->
    get_tree(Txn, Path, #{}).

get_tree(Txn, Path, Opts) when is_map(Opts) ->
    case maps:get(defaults, Opts, false) of
        true ->
            defaults_tree(Txn, Path);
        _ ->
            get_tree_stored(Txn, Path)
    end.

get_tree_stored(undefined, Path) ->
    case operational_tree(Path) of
        {ok, Tree} ->
            Tree;
        false ->
            get_tree_from(permanent, Path)
    end;
get_tree_stored(#cfg_txn{ets_copy = Copy}, Path) ->
    get_tree_from({ets, Copy}, Path).

operational_tree([]) ->
    false;
operational_tree(Path) ->
    Key = mgmtd_cfg_db:schema_path_to_key(Path),
    case mgmtd_schema:lookup(Key) of
        #{config := false} ->
            case mgmtd_provider:get_tree(Key) of
                {ok, Tree} ->
                    {ok, Tree};
                {error, _} ->
                    {ok, []}
            end;
        _ ->
            false
    end.

get_tree_from(Db, Path) ->
    ?DBG("Path = ~p~n",[Path]),
    Key = mgmtd_cfg_db:schema_path_to_key(Path),
    ?DBG("Key = ~p~n",[Key]),
    Rows = mgmtd_cfg_db:match_object(
             Db, #cfg{path = mgmtd_schema:ets_tail(Key),
                      _ = mgmtd_schema:ets_pat('_')}),
    SubRows = drop_path_prefix(Key, Rows),
    Tree = mgmtd_cfg_db:cfg_list_to_tree(SubRows),
    %% ?DBG("Tree ~p~n",[Tree]),
    SimpleTree = mgmtd_cfg_db:simplify_tree(Tree),
    %% ?DBG("Simple Tree ~p~n",[SimpleTree]),
    order_shown_list(Db, Key, SimpleTree).

%% We don't need the whole tree from the root if the user only requested part of the tree
%% so just drop nodes higher up the tree
%% Schema-driven tree with defaults filled in. List instances are only
%% those that exist; missing defaulted leaves under them are included.
defaults_tree(Txn, Path) ->
    ItemPath = to_item_path(Path),
    walk_children(Txn, ItemPath).

to_item_path([]) ->
    [];
to_item_path([#{role := schema} | _] = Path) ->
    mgmtd_cfg_db:schema_path_to_key(Path);
to_item_path(Path) when is_list(Path) ->
    Path.

walk_children(Txn, Parent) ->
    lists:filtermap(
      fun(Child) ->
              case walk_child(Txn, Parent, Child) of
                  omit -> false;
                  Entry -> {true, Entry}
              end
      end, mgmtd_schema:children(Parent, show)).

walk_child(_Txn, _Parent, #{config := false}) ->
    omit;
walk_child(Txn, Parent, #{name := Name, node_type := leaf} = Schema) ->
    Path = Parent ++ [Name],
    case leaf_value(Txn, Path, Schema) of
        none -> omit;
        {ok, V} -> {Name, {value, V}}
    end;
walk_child(Txn, Parent, #{name := Name, node_type := leaf_list} = Schema) ->
    Path = Parent ++ [Name],
    case leaf_list_value(Txn, Path, Schema) of
        [] -> omit;
        Vals -> {Name, {leaf_list, Vals}}
    end;
walk_child(Txn, Parent, #{name := Name, node_type := container}) ->
    Path = Parent ++ [Name],
    case walk_children(Txn, Path) of
        [] -> omit;
        Kids -> {Name, Kids}
    end;
walk_child(Txn, Parent, #{name := Name, node_type := list}) ->
    Path = Parent ++ [Name],
    Keys = list_keys_at(Txn, Path),
    Items =
        lists:filtermap(
          fun(Key) ->
                  case walk_children(Txn, Path ++ [Key]) of
                      [] -> false;
                      Kids -> {true, {Key, Kids}}
                  end
          end, Keys),
    case Items of
        [] -> omit;
        _ -> {Name, Items}
    end;
walk_child(_Txn, _Parent, _Schema) ->
    omit.

leaf_value(Txn, Path, Schema) ->
    case txn_leaf(Txn, Path) of
        {ok, V} ->
            {ok, V};
        none ->
            case maps:get(default, Schema, undefined) of
                undefined -> none;
                Default -> {ok, Default}
            end
    end.

leaf_list_value(Txn, Path, Schema) ->
    case txn_leaf(Txn, Path) of
        {ok, Vals} when is_list(Vals) ->
            Vals;
        _ ->
            case maps:get(default, Schema, undefined) of
                undefined -> [];
                Default when is_list(Default) -> Default;
                _ -> []
            end
    end.

txn_leaf(undefined, Path) ->
    try mgmtd:lookup(Path) of
        {ok, undefined} -> none;
        {ok, V} -> {ok, V};
        {error, _} -> none
    catch
        _:_ -> none
    end;
txn_leaf(#cfg_txn{ets_copy = Copy}, Path) ->
    case ets:lookup(Copy, Path) of
        [#cfg{value = V}] -> {ok, V};
        [] -> none
    end.

list_keys_at(#cfg_txn{} = Txn, Path) ->
    [K || K <- list_keys(Txn, Path, '$1'), is_tuple(K)];
list_keys_at(undefined, Path) ->
    try mgmtd:lookup(Path) of
        {ok, Keys} when is_list(Keys) ->
            [K || K <- Keys, is_tuple(K)];
        _ ->
            []
    catch
        _:_ ->
            []
    end.

%% Showing a list (not its parent) drops the list node, so zipper
%% sibling order is path order. Re-apply stored user order.
order_shown_list(Db, Path, Tree) ->
    case mgmtd_schema:lookup(Path) of
        #{node_type := list} ->
            Keys = [K || K <- mgmtd_cfg_db:list_keys(Db, Path, '$1'), is_tuple(K)],
            Map = maps:from_list([{K, V} || {K, V} <- Tree]),
            Ordered = [{K, maps:get(K, Map)} || K <- Keys, maps:is_key(K, Map)],
            Extra = [P || {K, _} = P <- Tree, not lists:member(K, Keys)],
            Ordered ++ Extra;
        _ ->
            Tree
    end.

drop_path_prefix(Path, [#cfg{path = FullPath, node_type = Leaf} = Cfg]) when Leaf == leaf; Leaf == leaf_list ->
    %% For a single leaf keep one parent - the name of the leaf itself
    PathLen = length(Path) - 1,
    [Cfg#cfg{path = lists:nthtail(PathLen, FullPath)}];
drop_path_prefix(Path, Rows) ->
    PathLen = length(Path),
    New = lists:map(fun(#cfg{path = FullPath} = Cfg) ->
                            ShortPath = lists:nthtail(PathLen, FullPath),
                            Cfg#cfg{path = ShortPath}
                    end, Rows),
    lists:filter(fun(#cfg{path = []}) -> false;
                    (_) -> true
                 end, New).

-spec set(#cfg_txn{}, map_path(), term()) -> {ok, #cfg_txn{}} | {error, term()}.
set(#cfg_txn{ets_copy = Copy, ops = Ops} = Txn, Path, Value) ->
    case mgmtd_schema:cast_value(Path, Value) of
        {ok, InternalValue} ->
            case mgmtd_schema:cast_list_key_values(Path) of
                {ok, Path1} ->
                    case mgmtd_cfg_db:check_conflict({ets, Copy}, Path1, InternalValue) of
                        ok ->
                            mgmtd_cfg_db:insert_path_items({ets, Copy}, Path1, InternalValue),
                            {ok, Txn#cfg_txn{ops = [{set, Path1, InternalValue} | Ops]}};
                        {error, Reason} ->
                            ?DBG(Reason),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

delete(#cfg_txn{ets_copy = Copy, ops = Ops} = Txn, Path) ->
    mgmtd_cfg_db:delete_path_items({ets, Copy}, Path),
    {ok, Txn#cfg_txn{ops = [{delete, Path} | Ops]}}.

%% @doc Reorder an existing `ordered-by user` list entry or leaf-list
%% value. `Path` is a schema path (from `lookup_path/1`) or an item
%% path. `Where` is `first` | `last` | `{before, Point}` | `{'after', Point}`
%% where `Point` is a list key tuple or a leaf-list value.
-spec move(#cfg_txn{}, map_path() | item_path(),
           first | last | {before, term()} | {'after', term()}) ->
          {ok, #cfg_txn{}} | {error, term()}.
move(#cfg_txn{ets_copy = Copy, ops = Ops} = Txn, Path, Where) ->
    ItemPath = move_item_path(Path),
    case mgmtd_cfg_db:move_item({ets, Copy}, ItemPath, Where) of
        {ok, _} ->
            {ok, Txn#cfg_txn{ops = [{move, ItemPath, Where} | Ops]}};
        {error, _} = Err ->
            Err
    end.

move_item_path([#{role := schema} | _] = Path) ->
    mgmtd_cfg_db:schema_path_to_key(Path);
move_item_path(Path) when is_list(Path) ->
    Path.

list_keys(undefined, Path, Pattern) ->
    mgmtd_cfg_db:list_keys(Path, Pattern);
list_keys(#cfg_txn{ets_copy = Copy}, Path, Pattern) ->
    mgmtd_cfg_db:list_keys({ets, Copy}, Path, Pattern).

-spec match_object(#cfg_txn{}, term()) -> [#cfg{}].
match_object(#cfg_txn{ets_copy = Copy}, Pattern) ->
    mgmtd_cfg_db:match_object({ets, Copy}, Pattern).



