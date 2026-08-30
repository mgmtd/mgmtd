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
         ets_copy
        }).

-type txn() :: #cfg_txn{}.

-export_type([txn/0]).

-export([new/0, exit_txn/1, get/2, get_tree/2, set/3, delete/2, list_keys/3, commit/1]).

new() ->
    TxnId = erlang:unique_integer(),
    #cfg_txn{txn_id = TxnId,
             ets_copy = mgmtd_cfg_db:copy_to_ets()
            }.

exit_txn(#cfg_txn{ets_copy = EtsCopy}) ->
    catch ets:delete(EtsCopy),
    ok.

%% @doc commit the operations stored up in the configuration transaction
commit(#cfg_txn{ops = Ops} = Txn) ->
    Fun = fun() ->
                  lists:foreach(fun({set, Path, Value}) ->
                                        mgmtd_cfg_db:insert_path_items(permanent, Path, Value);
                                   ({delete, Path}) ->
                                        mgmtd_cfg_db:delete_path_items(permanent, Path)
                                end, Ops)
          end,
    case mgmtd_cfg_db:transaction(Fun) of
        ok ->
            %% Other parts of the tree might have changed underneath us, so provide the user with
            %% a new transaction with a clean ets copy of the latest.
            %% Nice to have - detect if anything changed in other session(s) and warn the user
            %% about what was changed.
            ok = exit_txn(Txn),
            {ok, new()};
        Err ->
            %% The commit failed, leave the existing transaction alive so the user can
            %% fix the errors
            Err
    end.

-spec get(#cfg_txn{}, item_path()) -> {ok, any()} | undefined.
get(#cfg_txn{ets_copy = Copy}, Path) ->
    case ets:lookup(Copy, Path) of
        [#cfg{value = Value}] ->
            {ok, Value};
        [] ->
            mgmtd_schema:get_default(Path)
    end.

%% Operational mode (no config txn) reads committed config from the
%% backend. There is no named ETS table `cfg` — that was leftover from
%% an earlier ETS-only store.
get_tree(undefined, Path) ->
    get_tree_from(permanent, Path);
get_tree(#cfg_txn{ets_copy = Copy}, Path) ->
    get_tree_from({ets, Copy}, Path).

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
    SimpleTree.

%% We don't need the whole tree from the root if the user only requested part of the tree
%% so just drop nodes higher up the tree
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

-spec set(#cfg_txn{}, map_path(), term()) -> {ok, #cfg_txn{}} | {error, string()}.
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

list_keys(undefined, Path, Pattern) ->
    mgmtd_cfg_db:list_keys(Path, Pattern);
list_keys(#cfg_txn{ets_copy = Copy}, Path, Pattern) ->
    mgmtd_cfg_db:list_keys({ets, Copy}, Path, Pattern).



