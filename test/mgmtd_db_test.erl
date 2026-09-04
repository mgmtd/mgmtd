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
     [fun create_and_delete_list_item/0,
      fun create_and_delete_compound_key_list_item/0,
      fun create_with_invalid_keys/0,
      fun create_compound_list_item_keys_only/0,
      fun create_simple_list_item_keys_only/0,
      fun create_list_item_keys_only_then_set_leaf/0,
      fun create_list_item_keys_only_commit_then_set_leaf/0,
      fun create_second_list_item_keys_only/0,
      fun create_list_item_keys_only_idempotent/0,
      fun create_list_item_keys_only_invalid_keys/0,
      fun show_committed_without_txn/0,
      fun delete_then_readd_same_key_in_one_txn/0
     ]}.

create_and_delete_list_item() ->
    SetPath = ["server", "servers", {"newlistitem"}, "port", "81"],
    {ok, SchemaPath} = mgmtd_schema:lookup_path(SetPath),
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = mgmtd:txn_set(Txn, SchemaPath),
    {ok, Txn3} = mgmtd:txn_commit(Txn2),
    ?assertEqual(5, mnesia:table_info(cfg, size)),

    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"newlistitem"}, "port"])),

    DelPath = ["server", "servers", {"newlistitem"}],
    {ok, DelSchemaPath} = mgmtd_schema:lookup_path(DelPath),
    {ok, Txn4} = mgmtd:txn_delete(Txn3, DelSchemaPath),
    {ok, _} = mgmtd:txn_commit(Txn4),
    ?assertEqual(0, mnesia:table_info(cfg, size)).

create_and_delete_compound_key_list_item() ->
    SetPath = ["client", "clients", {"127.0.0.1", "82"}, "name", "Name"],
    {ok, SchemaPath} = mgmtd_schema:lookup_path(SetPath),
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = mgmtd:txn_set(Txn, SchemaPath),
    {ok, Txn3} = mgmtd:txn_commit(Txn2),
    ?assertEqual(6, mnesia:table_info(cfg, size)),

    ?assertEqual({ok, 82}, mgmtd:lookup(["client", "clients", {"127.0.0.1", "82"}, "port"])),

    DelPath = ["client", "clients", {"127.0.0.1", "82"}],
    {ok, DelSchemaPath} = mgmtd_schema:lookup_path(DelPath),
    {ok, Txn4} = mgmtd:txn_delete(Txn3, DelSchemaPath),
    {ok, _} = mgmtd:txn_commit(Txn4),
    ?assertEqual(0, mnesia:table_info(cfg, size)).

create_with_invalid_keys() ->
    SetPath = ["client", "clients", {"127.0.a.b", "82"}, "name", "Name"],
    {ok, SchemaPath} = mgmtd_schema:lookup_path(SetPath),
    Txn = mgmtd:txn_new(),
    ?assertEqual({error, "Invalid IP Address"}, mgmtd:txn_set(Txn, SchemaPath)).

%% Keys-only set creates the list identity in the txn. Non-key leaf
%% `name` stays unset. Commit is valid because `name` is optional.
create_compound_list_item_keys_only() ->
    Key = {"127.0.1.2", "82"},
    ItemPath = ["client", "clients", Key],
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = txn_set(Txn, ItemPath),

    ?assertEqual([Key], mgmtd:list_keys(Txn2, ["client", "clients"], '$1')),
    ?assertEqual({ok, ["host", "port"]}, mgmtd_cfg_txn:get(Txn2, ItemPath)),
    ?assertEqual({ok, {127,0,1,2}}, mgmtd_cfg_txn:get(Txn2, ItemPath ++ ["host"])),
    ?assertEqual({ok, 82}, mgmtd_cfg_txn:get(Txn2, ItemPath ++ ["port"])),
    ?assertEqual({ok, undefined}, mgmtd_cfg_txn:get(Txn2, ItemPath ++ ["name"])),

    %% Not visible in the committed store until commit
    ?assertEqual({ok, []}, mgmtd:lookup(["client", "clients"])),

    {ok, Txn3} = mgmtd:txn_commit(Txn2),
    ?assertEqual(5, mnesia:table_info(cfg, size)),
    ?assertEqual({ok, [Key]}, mgmtd:lookup(["client", "clients"])),
    ?assertEqual({ok, {127,0,1,2}}, mgmtd:lookup(ItemPath ++ ["host"])),
    ?assertEqual({ok, 82}, mgmtd:lookup(ItemPath ++ ["port"])),
    ?assertEqual({ok, undefined}, mgmtd:lookup(ItemPath ++ ["name"])),

    {ok, Txn4} = txn_delete(Txn3, ItemPath),
    {ok, _} = mgmtd:txn_commit(Txn4),
    ?assertEqual(0, mnesia:table_info(cfg, size)).

%% Single-key list: keys-only create writes the key leaf, not defaults.
create_simple_list_item_keys_only() ->
    Key = {"web1"},
    ItemPath = ["server", "servers", Key],
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = txn_set(Txn, ItemPath),

    ?assertEqual([Key], mgmtd:list_keys(Txn2, ["server", "servers"], '$1')),
    ?assertEqual({ok, ["name"]}, mgmtd_cfg_txn:get(Txn2, ItemPath)),
    ?assertEqual({ok, "web1"}, mgmtd_cfg_txn:get(Txn2, ItemPath ++ ["name"])),

    {ok, Txn3} = mgmtd:txn_commit(Txn2),
    ?assertEqual(4, mnesia:table_info(cfg, size)),
    ?assertEqual({ok, [Key]}, mgmtd:lookup(["server", "servers"])),
    ?assertEqual({ok, "web1"}, mgmtd:lookup(ItemPath ++ ["name"])),
    ?assertEqual({ok, "127.0.0.1"}, mgmtd:lookup(ItemPath ++ ["host"])),
    ?assertEqual({ok, 80}, mgmtd:lookup(ItemPath ++ ["port"])),

    {ok, Txn4} = txn_delete(Txn3, ItemPath),
    {ok, _} = mgmtd:txn_commit(Txn4),
    ?assertEqual(0, mnesia:table_info(cfg, size)).

%% Create the list identity, then fill a non-key leaf in the same txn.
create_list_item_keys_only_then_set_leaf() ->
    Key = {"127.0.1.2", "82"},
    ItemPath = ["client", "clients", Key],
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = txn_set(Txn, ItemPath),
    {ok, Txn3} = txn_set(Txn2, ItemPath ++ ["name", "Foo"]),

    ?assertEqual({ok, "Foo"}, mgmtd_cfg_txn:get(Txn3, ItemPath ++ ["name"])),
    ?assertEqual({ok, []}, mgmtd:lookup(["client", "clients"])),

    {ok, Txn4} = mgmtd:txn_commit(Txn3),
    ?assertEqual(6, mnesia:table_info(cfg, size)),
    ?assertEqual({ok, [Key]}, mgmtd:lookup(["client", "clients"])),
    ?assertEqual({ok, "Foo"}, mgmtd:lookup(ItemPath ++ ["name"])),

    {ok, Txn5} = txn_delete(Txn4, ItemPath),
    {ok, _} = mgmtd:txn_commit(Txn5),
    ?assertEqual(0, mnesia:table_info(cfg, size)).

%% Keys-only commit succeeds; a later txn can fill the remaining leaf.
create_list_item_keys_only_commit_then_set_leaf() ->
    Key = {"127.0.1.2", "82"},
    ItemPath = ["client", "clients", Key],
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = txn_set(Txn, ItemPath),
    {ok, Txn3} = mgmtd:txn_commit(Txn2),
    ?assertEqual({ok, undefined}, mgmtd:lookup(ItemPath ++ ["name"])),

    {ok, Txn4} = txn_set(Txn3, ItemPath ++ ["name", "Foo"]),
    {ok, Txn5} = mgmtd:txn_commit(Txn4),
    ?assertEqual({ok, "Foo"}, mgmtd:lookup(ItemPath ++ ["name"])),
    ?assertEqual(6, mnesia:table_info(cfg, size)),

    {ok, Txn6} = txn_delete(Txn5, ItemPath),
    {ok, _} = mgmtd:txn_commit(Txn6),
    ?assertEqual(0, mnesia:table_info(cfg, size)).

%% Keys-only create of a second item once the list already exists.
create_second_list_item_keys_only() ->
    Key1 = {"127.0.1.2", "82"},
    Key2 = {"10.0.0.1", "83"},
    Item1 = ["client", "clients", Key1],
    Item2 = ["client", "clients", Key2],
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = txn_set(Txn, Item1),
    {ok, Txn3} = txn_set(Txn2, Item2),

    ?assertEqual(lists:sort([Key1, Key2]),
                 lists:sort(mgmtd:list_keys(Txn3, ["client", "clients"], '$1'))),

    {ok, Txn4} = mgmtd:txn_commit(Txn3),
    ?assertEqual({ok, lists:sort([Key1, Key2])},
                 sort_ok(mgmtd:lookup(["client", "clients"]))),
    ?assertEqual(8, mnesia:table_info(cfg, size)),

    {ok, Txn5} = txn_delete(Txn4, Item1),
    {ok, Txn6} = txn_delete(Txn5, Item2),
    {ok, _} = mgmtd:txn_commit(Txn6),
    ?assertEqual(0, mnesia:table_info(cfg, size)).

create_list_item_keys_only_idempotent() ->
    Key = {"127.0.1.2", "82"},
    ItemPath = ["client", "clients", Key],
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = txn_set(Txn, ItemPath),
    {ok, Txn3} = txn_set(Txn2, ItemPath),
    ?assertEqual([Key], mgmtd:list_keys(Txn3, ["client", "clients"], '$1')),

    {ok, Txn4} = mgmtd:txn_commit(Txn3),
    ?assertEqual({ok, [Key]}, mgmtd:lookup(["client", "clients"])),

    {ok, Txn5} = txn_delete(Txn4, ItemPath),
    {ok, _} = mgmtd:txn_commit(Txn5),
    ?assertEqual(0, mnesia:table_info(cfg, size)).

create_list_item_keys_only_invalid_keys() ->
    Txn = mgmtd:txn_new(),
    ?assertEqual({error, "Invalid IP Address"},
                 txn_set(Txn, ["client", "clients", {"127.0.a.b", "82"}])).

%% `show configuration` from operational mode (Txn = undefined) must
%% read committed config from the backend, not a leftover named ETS
%% table `cfg`.
show_committed_without_txn() ->
    ?assertEqual({ok, []}, mgmtd:txn_show(undefined, [])),
    ?assertEqual([], mgmtd:list_keys(undefined, ["server", "servers"], '$1')),

    {ok, Txn} = txn_set(mgmtd:txn_new(),
                        ["server", "servers", {"web1"}, "port", "81"]),
    {ok, Txn2} = mgmtd:txn_commit(Txn),
    {ok, FromTxn} = mgmtd:txn_show(Txn2, []),
    {ok, FromCommitted} = mgmtd:txn_show(undefined, []),
    ?assertEqual(FromTxn, FromCommitted),
    ?assertMatch([{"server", _}], FromCommitted),
    ?assertEqual([{"web1"}],
                 mgmtd:list_keys(undefined, ["server", "servers"], '$1')),

    {ok, ServerSchema} = mgmtd_schema:lookup_path(["server"]),
    {ok, Subtree} = mgmtd:txn_show(undefined, ServerSchema),
    ?assertMatch([{"servers", _}], Subtree),

    {ok, _} = txn_delete_commit(Txn2, ["server", "servers", {"web1"}]).

%% Delete a list item then create it again with different leaves in the
%% same session. Commit must keep the re-add, not replay newest-first
%% (set then delete) and drop it.
delete_then_readd_same_key_in_one_txn() ->
    Key = {"web1"},
    Item = ["server", "servers", Key],
    {ok, Txn} = txn_set(mgmtd:txn_new(), Item ++ ["port", "81"]),
    {ok, Txn2} = mgmtd:txn_commit(Txn),
    ?assertEqual({ok, 81}, mgmtd:lookup(Item ++ ["port"])),

    {ok, Txn3} = txn_delete(Txn2, Item),
    {ok, Txn4} = txn_set(Txn3, Item ++ ["port", "9999"]),
    {ok, _} = mgmtd:txn_commit(Txn4),
    ?assertEqual({ok, [Key]}, mgmtd:lookup(["server", "servers"])),
    ?assertEqual({ok, 9999}, mgmtd:lookup(Item ++ ["port"])),
    ?assertEqual({ok, "127.0.0.1"}, mgmtd:lookup(Item ++ ["host"])).

txn_set(Txn, Path) ->
    {ok, SchemaPath} = mgmtd_schema:lookup_path(Path),
    mgmtd:txn_set(Txn, SchemaPath).

txn_delete(Txn, Path) ->
    {ok, SchemaPath} = mgmtd_schema:lookup_path(Path),
    mgmtd:txn_delete(Txn, SchemaPath).

txn_delete_commit(Txn, Path) ->
    {ok, Txn2} = txn_delete(Txn, Path),
    mgmtd:txn_commit(Txn2).

sort_ok({ok, List}) ->
    {ok, lists:sort(List)}.

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
