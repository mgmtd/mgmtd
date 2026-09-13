-module(mgmtd_diff_test).

-include_lib("eunit/include/eunit.hrl").

-define(DB_DIR, "test_db_diff").

%%--------------------------------------------------------------------
setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, mnesia}]),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ok = mgmtd_cfg_db:init(?DB_DIR, [{backend, mnesia}, {rollback, 10}]),
    ok.

teardown(_) ->
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, mnesia}]),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

diff_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [fun empty_session_is_no_diff/0,
      fun no_txn_is_no_diff/0,
      fun add_list_item/0,
      fun change_existing_leaf/0,
      fun delete_list_item/0,
      fun path_limits_diff/0,
      fun set_then_revert_is_no_diff/0,
      fun format_add_and_set/0,
      fun against_running/0,
      fun rollback_loaded_session/0]}.

%%--------------------------------------------------------------------
empty_session_is_no_diff() ->
    Txn = mgmtd:txn_new(),
    ?assertEqual({ok, []}, mgmtd:txn_diff(Txn)),
    ?assertEqual({ok, []}, mgmtd:txn_diff_text(Txn)),
    ok = mgmtd:txn_exit(Txn).

no_txn_is_no_diff() ->
    ?assertEqual({ok, []}, mgmtd:txn_diff(undefined)).

add_list_item() ->
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = txn_set(Txn, ["server", "servers", {"web1"}, "port", "81"]),
    {ok, Changes} = mgmtd:txn_diff(Txn2),
    ?assertMatch([{add, ["server"], _}], Changes),
    [{add, ["server"], Tree}] = Changes,
    Servers = proplists:get_value("servers", Tree),
    Item = proplists:get_value({"web1"}, Servers),
    ?assertEqual({value, 81}, proplists:get_value("port", Item)),
    ok = mgmtd:txn_exit(Txn2).

change_existing_leaf() ->
    {ok, _} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = txn_set(Txn, ["server", "servers", {"web1"}, "port", "90"]),
    ?assertEqual({ok, [{set, ["server", "servers", {"web1"}, "port"], 81, 90}]},
                 mgmtd:txn_diff(Txn2)),
    ok = mgmtd:txn_exit(Txn2).

delete_list_item() ->
    {ok, Txn} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    {ok, Txn2} = txn_delete(Txn, ["server", "servers", {"web1"}]),
    {ok, Changes} = mgmtd:txn_diff(Txn2),
    ?assertMatch([{delete, ["server"], _}], Changes),
    ok = mgmtd:txn_exit(Txn2).

path_limits_diff() ->
    {ok, _} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    {ok, _} = commit_set(["client", "clients", {"127.0.0.1", "82"}, "name", "c1"]),
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = txn_set(Txn, ["server", "servers", {"web1"}, "port", "90"]),
    {ok, Txn3} = txn_set(Txn2, ["client", "clients", {"127.0.0.1", "82"}, "name", "c2"]),
    {ok, Server} = mgmtd:txn_diff(Txn3, ["server"]),
    {ok, Client} = mgmtd:txn_diff(Txn3, ["client"]),
    ?assertEqual([{set, ["server", "servers", {"web1"}, "port"], 81, 90}], Server),
    ?assertEqual([{set, ["client", "clients", {"127.0.0.1", "82"}, "name"],
                   "c1", "c2"}], Client),
    ok = mgmtd:txn_exit(Txn3).

set_then_revert_is_no_diff() ->
    {ok, _} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = txn_set(Txn, ["server", "servers", {"web1"}, "port", "90"]),
    {ok, Txn3} = txn_set(Txn2, ["server", "servers", {"web1"}, "port", "81"]),
    ?assertEqual({ok, []}, mgmtd:txn_diff(Txn3)),
    ok = mgmtd:txn_exit(Txn3).

format_add_and_set() ->
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = txn_set(Txn, ["server", "servers", {"web1"}, "port", "81"]),
    {ok, Text} = mgmtd:txn_diff_text(Txn2),
    Bin = iolist_to_binary(Text),
    ?assertEqual(true, binary:match(Bin, <<"[edit]">>) =/= nomatch),
    ?assertEqual(true, binary:match(Bin, <<"+  server {">>) =/= nomatch),
    ?assertEqual(true, binary:match(Bin, <<"+    servers {">>) =/= nomatch),
    ?assertEqual(true, binary:match(Bin, <<"port 81;">>) =/= nomatch),
    ok = mgmtd:txn_exit(Txn2),

    {ok, _} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    Txn3 = mgmtd:txn_new(),
    {ok, Txn4} = txn_set(Txn3, ["server", "servers", {"web1"}, "port", "90"]),
    {ok, Text2} = mgmtd:txn_diff_text(Txn4),
    Bin2 = iolist_to_binary(Text2),
    ?assertEqual(true, binary:match(Bin2, <<"[edit server servers web1]">>) =/= nomatch),
    ?assertEqual(true, binary:match(Bin2, <<"-  port 81;">>) =/= nomatch),
    ?assertEqual(true, binary:match(Bin2, <<"+  port 90;">>) =/= nomatch),
    ok = mgmtd:txn_exit(Txn4).

against_running() ->
    {ok, _} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = txn_set(Txn, ["server", "servers", {"web1"}, "port", "90"]),
    {ok, VsSession} = mgmtd:txn_diff(Txn2, [], #{against => session}),
    {ok, VsRunning} = mgmtd:txn_diff(Txn2, [], #{against => running}),
    ?assertEqual(VsSession, VsRunning),
    ?assertEqual({error, {unknown_against, bogus}},
                 mgmtd:txn_diff(Txn2, [], #{against => bogus})),
    ok = mgmtd:txn_exit(Txn2).

rollback_loaded_session() ->
    {ok, _} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    {ok, _} = commit_set(["server", "servers", {"web1"}, "port", "90"]),
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = mgmtd:txn_rollback(Txn, 1),
    ?assertEqual({ok, [{set, ["server", "servers", {"web1"}, "port"], 90, 81}]},
                 mgmtd:txn_diff(Txn2)),
    %% Session tree is rollback 1, so compare against that snapshot is empty.
    ?assertEqual({ok, []}, mgmtd:txn_diff(Txn2, [], #{against => {rollback, 1}})),
    ?assertMatch({error, {unknown_rollback, _}},
                 mgmtd:txn_diff(Txn2, [], #{against => {rollback, 99}})),
    ok = mgmtd:txn_exit(Txn2).

%%--------------------------------------------------------------------
commit_set(Path) ->
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = txn_set(Txn, Path),
    mgmtd:txn_commit(Txn2).

txn_set(Txn, Path) ->
    {ok, SchemaPath} = mgmtd_schema:lookup_path(Path),
    mgmtd:txn_set(Txn, SchemaPath).

txn_delete(Txn, Path) ->
    {ok, SchemaPath} = mgmtd_schema:lookup_path(Path),
    mgmtd:txn_delete(Txn, SchemaPath).
