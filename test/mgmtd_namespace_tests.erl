-module(mgmtd_namespace_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DB_DIR, "test_db_ns").

setup() ->
    start_mgmtd(),
    ok = mgmtd:remove_schema(),
    ok = mgmtd:remove_schema(example),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, mnesia}]),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                    #{namespace => example}),
    ok = mgmtd_cfg_db:init(?DB_DIR, [{backend, mnesia}]),
    ok.

teardown(_) ->
    ok = mgmtd:remove_schema(),
    ok = mgmtd:remove_schema(example),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, mnesia}]),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

namespace_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun prefixed_and_default_list_items_are_independent/0,
      fun prefixed_lookup_path_includes_prefix_container/0,
      fun subscribe_prefixed_list/0]}.

prefixed_and_default_list_items_are_independent() ->
    SetDefault = ["server", "servers", {"def1"}, "port", "81"],
    {ok, DefaultPath} = mgmtd_schema:lookup_path(SetDefault),
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = mgmtd:txn_set(Txn, DefaultPath),
    {ok, Txn3} = mgmtd:txn_commit(Txn2),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"def1"}, "port"])),
    ?assertEqual({ok, []}, mgmtd:lookup(["example", "server", "servers"])),

    SetPrefixed = ["example", "server", "servers", {"ex1"}, "port", "82"],
    {ok, PrefixedPath} = mgmtd_schema:lookup_path(SetPrefixed),
    {ok, Txn4} = mgmtd:txn_set(Txn3, PrefixedPath),
    {ok, Txn5} = mgmtd:txn_commit(Txn4),
    ?assertEqual({ok, 82}, mgmtd:lookup(["example", "server", "servers", {"ex1"}, "port"])),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"def1"}, "port"])),
    ?assertEqual({ok, [{"def1"}]}, mgmtd:lookup(["server", "servers"])),
    ?assertEqual({ok, [{"ex1"}]}, mgmtd:lookup(["example", "server", "servers"])),
    ?assertEqual({ok, lists:sort(["client", "interface", "server"])},
                 sort_ok(mgmtd:lookup(["example"]))),

    DelPrefixed = ["example", "server", "servers", {"ex1"}],
    {ok, DelPath} = mgmtd_schema:lookup_path(DelPrefixed),
    {ok, Txn6} = mgmtd:txn_delete(Txn5, DelPath),
    {ok, _} = mgmtd:txn_commit(Txn6),
    ?assertEqual({ok, []}, mgmtd:lookup(["example", "server", "servers"])),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"def1"}, "port"])).

prefixed_lookup_path_includes_prefix_container() ->
    {ok, Path} = mgmtd_schema:lookup_path(
                   ["example", "server", "servers", {"ex1"}, "port", "9"]),
    ?assertMatch([#{name := "example", node_type := container, ns := example},
                  #{name := "server", ns := example},
                  #{name := "servers", node_type := list, ns := example},
                  #{name := "port", node_type := leaf, ns := example, value := "9"}],
                 Path).

subscribe_prefixed_list() ->
    {ok, Ref} = mgmtd:subscribe(["example", "server", "servers"], self()),
    receive
        {updated_config, Ref, Updated} ->
            ?assertEqual([], Updated)
    after 1000 ->
            error(init_subscription_not_received)
    end,
    SetPath = ["example", "server", "servers", {"n1"}, "port", "81"],
    {ok, SchemaPath} = mgmtd_schema:lookup_path(SetPath),
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = mgmtd:txn_set(Txn, SchemaPath),
    {ok, _} = mgmtd:txn_commit(Txn2),
    receive
        {updated_config, Ref, Updated1} ->
            ?assertEqual([{"n1"}], Updated1)
    after 1000 ->
            error(subscription_not_received)
    end.

sort_ok({ok, List}) ->
    {ok, lists:sort(List)}.
