%%%-------------------------------------------------------------------
%%% @author Sean Hinde <sean@Seans-MacBook.local>
%%% @copyright (C) 2019, Sean Hinde
%%% @doc Eunit tests for configuration subscriptions
%%%
%%% @end
%%% Created : 7 Nov 2019 by Sean Hinde <sean@Seans-MacBook.local>
%%%-------------------------------------------------------------------
-module(mgmtd_subscriptions_test).

-include_lib("eunit/include/eunit.hrl").

-define(DB_DIR, "test_db_subs").

setup() ->
    start_mgmtd(),
    clear_subscriptions(),
    ok = mgmtd:remove_schema(),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, mnesia}]),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ok = mgmtd_cfg_db:init(?DB_DIR, [{backend, mnesia}]),
    ok.

teardown(_) ->
    clear_subscriptions(),
    ok = mgmtd:remove_schema(),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, mnesia}]),
    flush(),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

clear_subscriptions() ->
    lists:foreach(fun({{_Path, _Pid, Ref}, _}) ->
                          mgmtd_cfg_server:unsubscribe(Ref)
                  end, mgmtd_cfg_server:subscriptions()).

subscription_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [fun subscribe_unknown_path/0,
      fun subscribe_list_add_delete_and_set/0,
      fun subscribe_specific_list_key/0,
      fun subscribe_leaf_without_list_instance/0,
      fun subscribe_leaf_with_list_instance/0,
      fun subscribe_container_subtree/0,
      fun subscribe_ops_order_delete_add_set/0,
      fun subscribe_compound_list_keys/0,
      fun subscribe_ignores_unrelated_changes/0,
      fun subscribe_delete_then_readd_same_key/0]}.

subscribe_unknown_path() ->
    ?assertEqual({error, unknown_schema_path},
                 mgmtd:subscribe(["no-such-node"], self())).

%% List subscription: add/delete of instances plus set of leaves in
%% the subtree, including on first snapshot.
subscribe_list_add_delete_and_set() ->
    {ok, Ref} = mgmtd:subscribe(["server", "servers"], self()),
    ?assertEqual([], recv_change(Ref)),

    {ok, Txn} = set_commit(mgmtd:txn_new(),
                           ["server", "servers", {"newlistitem"}, "port", "81"]),
    ?assertEqual([{add, ["server", "servers"], {"newlistitem"}},
                  {set, ["server", "servers", {"newlistitem"}, "name"], "newlistitem"},
                  {set, ["server", "servers", {"newlistitem"}, "port"], 81}],
                 recv_change(Ref)),

    {ok, Txn2} = set_commit(Txn, ["server", "servers", {"newlistitem"}, "port", "8080"]),
    ?assertEqual([{set, ["server", "servers", {"newlistitem"}, "port"], 8080}],
                 recv_change(Ref)),

    {ok, _} = delete_commit(Txn2, ["server", "servers", {"newlistitem"}]),
    ?assertEqual([{delete, ["server", "servers"], {"newlistitem"}}],
                 recv_change(Ref)).

%% A path that names a list instance only reports that instance.
subscribe_specific_list_key() ->
    {ok, Txn} = set_commit(mgmtd:txn_new(),
                           ["server", "servers", {"keep"}, "port", "81"]),
    {ok, Txn2} = set_commit(Txn, ["server", "servers", {"other"}, "port", "82"]),

    {ok, Ref} = mgmtd:subscribe(["server", "servers", {"keep"}], self()),
    ?assertEqual([{add, ["server", "servers"], {"keep"}},
                  {set, ["server", "servers", {"keep"}, "name"], "keep"},
                  {set, ["server", "servers", {"keep"}, "port"], 81}],
                 recv_change(Ref)),

    {ok, Txn3} = set_commit(Txn2, ["server", "servers", {"keep"}, "port", "8080"]),
    ?assertEqual([{set, ["server", "servers", {"keep"}, "port"], 8080}],
                 recv_change(Ref)),

    {ok, Txn4} = set_commit(Txn3, ["server", "servers", {"other"}, "port", "99"]),
    assert_no_change(Ref),

    {ok, _} = delete_commit(Txn4, ["server", "servers", {"keep"}]),
    ?assertEqual([{delete, ["server", "servers"], {"keep"}}],
                 recv_change(Ref)).

%% Leaf path with the list instance omitted matches that leaf on every item.
subscribe_leaf_without_list_instance() ->
    {ok, Ref} = mgmtd:subscribe(["server", "servers", "port"], self()),
    ?assertEqual([], recv_change(Ref)),

    {ok, Txn} = set_commit(mgmtd:txn_new(),
                           ["server", "servers", {"a"}, "port", "81"]),
    ?assertEqual([{add, ["server", "servers"], {"a"}},
                  {set, ["server", "servers", {"a"}, "port"], 81}],
                 recv_change(Ref)),

    {ok, Txn2} = set_commit(Txn, ["server", "servers", {"b"}, "port", "82"]),
    ?assertEqual([{add, ["server", "servers"], {"b"}},
                  {set, ["server", "servers", {"b"}, "port"], 82}],
                 recv_change(Ref)),

    {ok, Txn3} = set_commit(Txn2, ["server", "servers", {"a"}, "host", "10.0.0.1"]),
    assert_no_change(Ref),

    {ok, _} = set_commit(Txn3, ["server", "servers", {"a"}, "port", "8080"]),
    ?assertEqual([{set, ["server", "servers", {"a"}, "port"], 8080}],
                 recv_change(Ref)).

%% Leaf path that names the instance only sees that leaf.
subscribe_leaf_with_list_instance() ->
    {ok, Txn} = set_commit(mgmtd:txn_new(),
                           ["server", "servers", {"a"}, "port", "81"]),
    {ok, Txn2} = set_commit(Txn, ["server", "servers", {"b"}, "port", "82"]),

    {ok, Ref} = mgmtd:subscribe(["server", "servers", {"a"}, "port"], self()),
    ?assertEqual([{add, ["server", "servers"], {"a"}},
                  {set, ["server", "servers", {"a"}, "port"], 81}],
                 recv_change(Ref)),

    {ok, _} = set_commit(Txn2, ["server", "servers", {"b"}, "port", "99"]),
    assert_no_change(Ref).

%% Container subscription includes list add/delete/set in the subtree.
subscribe_container_subtree() ->
    {ok, Ref} = mgmtd:subscribe(["server"], self()),
    ?assertEqual([], recv_change(Ref)),

    {ok, _} = set_commit(mgmtd:txn_new(),
                         ["server", "servers", {"web"}, "port", "81"]),
    ?assertEqual([{add, ["server", "servers"], {"web"}},
                  {set, ["server", "servers", {"web"}, "name"], "web"},
                  {set, ["server", "servers", {"web"}, "port"], 81}],
                 recv_change(Ref)),

    {ok, IfRef} = mgmtd:subscribe(["interface"], self()),
    ?assertEqual([], recv_change(IfRef)),
    {ok, _} = set_commit(mgmtd:txn_new(), ["interface", "speed", "1GbE"]),
    ?assertEqual([{set, ["interface", "speed"], "1GbE"}],
                 recv_change(IfRef)),
    assert_no_change(Ref).

%% Mixed commit: deletes, then adds, then leaf sets.
subscribe_ops_order_delete_add_set() ->
    {ok, Txn} = set_commit(mgmtd:txn_new(),
                           ["server", "servers", {"a"}, "port", "81"]),
    {ok, Txn2} = set_commit(Txn, ["server", "servers", {"b"}, "port", "82"]),

    {ok, Ref} = mgmtd:subscribe(["server", "servers"], self()),
    _Snapshot = recv_change(Ref),

    {ok, SchemaDel} = mgmtd_schema:lookup_path(["server", "servers", {"a"}]),
    {ok, Txn3} = mgmtd:txn_delete(Txn2, SchemaDel),
    {ok, Txn4} = txn_set(Txn3, ["server", "servers", {"c"}, "port", "83"]),
    {ok, Txn5} = txn_set(Txn4, ["server", "servers", {"b"}, "port", "99"]),
    {ok, _} = mgmtd:txn_commit(Txn5),

    ?assertEqual([{delete, ["server", "servers"], {"a"}},
                  {add, ["server", "servers"], {"c"}},
                  {set, ["server", "servers", {"b"}, "port"], 99},
                  {set, ["server", "servers", {"c"}, "name"], "c"},
                  {set, ["server", "servers", {"c"}, "port"], 83}],
                 recv_change(Ref)).

subscribe_compound_list_keys() ->
    Key = {"127.0.0.1", "82"},
    {ok, Ref} = mgmtd:subscribe(["client", "clients"], self()),
    ?assertEqual([], recv_change(Ref)),

    {ok, Txn} = set_commit(mgmtd:txn_new(),
                           ["client", "clients", Key, "name", "Name"]),
    ?assertEqual([{add, ["client", "clients"], Key},
                  {set, ["client", "clients", Key, "host"], {127,0,0,1}},
                  {set, ["client", "clients", Key, "name"], "Name"},
                  {set, ["client", "clients", Key, "port"], 82}],
                 recv_change(Ref)),

    {ok, _} = delete_commit(Txn, ["client", "clients", Key]),
    ?assertEqual([{delete, ["client", "clients"], Key}],
                 recv_change(Ref)).

subscribe_ignores_unrelated_changes() ->
    {ok, Ref} = mgmtd:subscribe(["interface", "speed"], self()),
    ?assertEqual([], recv_change(Ref)),

    {ok, _} = set_commit(mgmtd:txn_new(),
                         ["server", "servers", {"web"}, "port", "81"]),
    assert_no_change(Ref).

%% Delete + re-add of the same list key in one session is squashed to
%% the net leaf changes. No delete/add of the instance.
subscribe_delete_then_readd_same_key() ->
    Key = {"web1"},
    Item = ["server", "servers", Key],
    {ok, Txn} = set_commit(mgmtd:txn_new(), Item ++ ["port", "81"]),
    {ok, Txn2} = set_commit(Txn, Item ++ ["host", "10.0.0.1"]),

    {ok, Ref} = mgmtd:subscribe(["server", "servers"], self()),
    _Snapshot = recv_change(Ref),

    {ok, Txn3} = txn_delete(Txn2, Item),
    {ok, Txn4} = txn_set(Txn3, Item ++ ["port", "9999"]),
    {ok, _} = mgmtd:txn_commit(Txn4),

    ?assertEqual([{set, Item ++ ["host"], "127.0.0.1"},
                  {set, Item ++ ["port"], 9999}],
                 recv_change(Ref)).

set_commit(Txn, Path) ->
    {ok, Txn2} = txn_set(Txn, Path),
    mgmtd:txn_commit(Txn2).

delete_commit(Txn, Path) ->
    {ok, SchemaPath} = mgmtd_schema:lookup_path(Path),
    {ok, Txn2} = mgmtd:txn_delete(Txn, SchemaPath),
    mgmtd:txn_commit(Txn2).

txn_set(Txn, Path) ->
    {ok, SchemaPath} = mgmtd_schema:lookup_path(Path),
    mgmtd:txn_set(Txn, SchemaPath).

txn_delete(Txn, Path) ->
    {ok, SchemaPath} = mgmtd_schema:lookup_path(Path),
    mgmtd:txn_delete(Txn, SchemaPath).

recv_change(Ref) ->
    receive
        {config_change, Ref, Ops} ->
            Ops
    after 1000 ->
            error({subscription_not_received, process_info(self(), messages)})
    end.

assert_no_change(Ref) ->
    receive
        {config_change, Ref, Ops} ->
            error({unexpected_config_change, Ops})
    after 150 ->
            ok
    end.

flush() ->
    receive
        {config_change, _, _} ->
            flush()
    after 0 ->
            ok
    end.
