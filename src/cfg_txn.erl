%%%-------------------------------------------------------------------
%%% @author Sean Hinde <sean@Seans-MacBook.local>
%%% @copyright (C) 2019, Sean Hinde
%%% @doc Configuration transaction handler
%%%
%%% @end
%%% Created : 18 Sep 2019 by Sean Hinde <sean@Seans-MacBook.local>
%%%-------------------------------------------------------------------
-module(cfg_txn).

-record(cfg_txn,
        {
         txn_id,
         ops = [],
         copy_ets
         }).


-export([new/0, get/2, set/3, commit/1]).

new() ->
    TxnId = erlang:now(),
    #cfg_txn{txn_id = TxnId,
             copy_ets = {ets_copy, cfg_db:copy_to_ets()}
            }.


-spec get(#cfg_txn{}, cfg:path()) -> {ok, cfg:value()} | undefined.
get(#cfg_txn{copy_ets = Copy}, Path) ->
    case cfg_db:lookup(Copy, Path) of
        {ok, Value} ->
            {ok, Value};
        false ->
            cfg_schema:lookup_default(Path)
    end.

set(#cfg_txn{copy_ets = Copy, ops = Ops} = Txn, Path, Value) ->
    case cfg_db:insert(Copy, Path, Value) of
        ok ->
            Txn#cfg_txn{ops = [{set, Path, Value} | Ops]};
        {error, _Reason} = Err ->
            throw(Err)
    end.

commit(#cfg_txn{copy_ets = {ets_copy, Copy}, ops = Ops}) ->
    case cfg_db:apply_ops(Ops) of
        ok ->
            ets:delete(Copy),
            ok;
        Err ->
            ets:delete(Copy),
            Err
    end.
