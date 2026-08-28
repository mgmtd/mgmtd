%%%-------------------------------------------------------------------
%%% @author Sean Hinde <sean@Seans-MacBook.local>
%%% @copyright (C) 2019, Sean Hinde
%%% @doc Eunit tests for cfg_db
%%%
%%% @end
%%% Created : 15 Feb 2025 by Sean Hinde <sean@Seans-MacBook.local>
%%%-------------------------------------------------------------------
-module(mgmtd_db_test).

-include("../src/mgmtd_schema.hrl").

-include_lib("eunit/include/eunit.hrl").

-define(DB_DIR, "test_db").

setup() ->
    start_mgmtd(),
    ok = mgmtd:remove_schema(),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, mnesia}]),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
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

list_item_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun create_and_delete_list_item/0]}.

create_and_delete_list_item() ->
    SetPath = ["server", "servers", {"newlistitem"}, "port", "81"],
    {ok, SchemaPath} = mgmtd_schema:lookup_path(SetPath),
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = mgmtd:txn_set(Txn, SchemaPath),
    {ok, Txn3} = mgmtd:txn_commit(Txn2),
    ?assertEqual(5, mnesia:table_info(cfg, size)),

    DelPath = ["server", "servers", {"newlistitem"}],
    {ok, DelSchemaPath} = mgmtd_schema:lookup_path(DelPath),
    {ok, Txn4} = mgmtd:txn_delete(Txn3, DelSchemaPath),
    {ok, _} = mgmtd:txn_commit(Txn4),
    ?assertEqual(0, mnesia:table_info(cfg, size)).

enum_leaf_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun set_enum_with_description/0,
      fun reject_unknown_enum/0]}.

set_enum_with_description() ->
    SetPath = ["interface", "speed", "1GbE"],
    {ok, SchemaPath} = mgmtd_schema:lookup_path(SetPath),
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = mgmtd:txn_set(Txn, SchemaPath),
    {ok, _} = mgmtd:txn_commit(Txn2),
    ?assertEqual({ok, "1GbE"}, mgmtd:lookup(["interface", "speed"])).

reject_unknown_enum() ->
    SetPath = ["interface", "speed", "67"],
    {ok, SchemaPath} = mgmtd_schema:lookup_path(SetPath),
    Txn = mgmtd:txn_new(),
    ?assertEqual({error, "Unknown enum value"}, mgmtd:txn_set(Txn, SchemaPath)).
