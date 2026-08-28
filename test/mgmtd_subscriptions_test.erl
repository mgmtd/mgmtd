%%%-------------------------------------------------------------------
%%% @author Sean Hinde <sean@Seans-MacBook.local>
%%% @copyright (C) 2019, Sean Hinde
%%% @doc Eunit tests for cfg_db
%%%
%%% @end
%%% Created : 7 Nov 2019 by Sean Hinde <sean@Seans-MacBook.local>
%%%-------------------------------------------------------------------
-module(mgmtd_subscriptions_test).

-include_lib("eunit/include/eunit.hrl").

-define(DB_DIR, "test_db_subs").

setup() ->
    start_mgmtd(),
    ok = mgmtd:remove_schema(),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, mnesia}]),
    ok = mgmtd:load_function_schema(fun() -> mgmtd_test_schema:cfg_schema() end),
    ok = mgmtd_cfg_db:init(?DB_DIR, [{backend, mnesia}]),
    ok.

teardown(_) ->
    ok = mgmtd:remove_schema(),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, mnesia}]),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

subscription_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun subscribe_list_and_item/0]}.

subscribe_list_and_item() ->
    {ok, Ref} = mgmtd:subscribe(["server", "servers"], self()),
    receive
        {updated_config, Ref, Updated} ->
            ?assertEqual([], Updated)
    after 1000 ->
            error(init_subscription_not_received)
    end,

    SetPath = ["server", "servers", {"newlistitem"}, "port", "81"],
    {ok, SchemaPath} = mgmtd_schema:lookup_path(SetPath),
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = mgmtd:txn_set(Txn, SchemaPath),
    {ok, Txn3} = mgmtd:txn_commit(Txn2),
    receive
        {updated_config, Ref, Updated1} ->
            ?assertEqual([{"newlistitem"}], Updated1)
    after 1000 ->
            error(subscription_not_received)
    end,

    {ok, Ref2} = mgmtd:subscribe(["server", "servers", {"newlistitem"}], self()),
    receive
        {updated_config, Ref2, Updated2} ->
            ?assertEqual([{"name", "newlistitem"}, {"port", 81}],
                         lists:sort(Updated2))
    after 1000 ->
            error(subscription_not_received)
    end,

    UpdPath = ["server", "servers", {"newlistitem"}, "port", "8080"],
    {ok, SchemaPath1} = mgmtd_schema:lookup_path(UpdPath),
    {ok, Txn4} = mgmtd:txn_set(Txn3, SchemaPath1),
    {ok, _} = mgmtd:txn_commit(Txn4),
    receive
        {updated_config, Ref2, Updated3} ->
            ?assertEqual([{"host", "127.0.0.1"}, {"port", 8080}],
                         lists:sort(Updated3))
    after 1000 ->
            error(subscription_not_received)
    end.
