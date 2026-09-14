%%%-------------------------------------------------------------------
%%% @doc Concurrent configure sessions: disjoint edits commit, overlapping
%%% edits return `{error, {conflict, Path}}`.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_conflict_test).

-include_lib("eunit/include/eunit.hrl").

-define(M_DIR, "test_db_conflict_mnesia").
-define(S_DIR, "test_db_conflict_sys").
-define(J_DIR, "test_db_conflict_json").

%%--------------------------------------------------------------------
%% Mnesia
%%--------------------------------------------------------------------
mnesia_test_() ->
    {foreach, fun() -> setup(mnesia, ?M_DIR) end,
     fun(_) -> teardown(mnesia, ?M_DIR) end,
     [fun disjoint_edits_both_commit/0,
      fun same_leaf_second_conflicts/0,
      fun same_value_second_is_ok/0,
      fun different_leaves_same_item_merge/0,
      fun delete_vs_set_same_item_conflicts/0,
      fun delete_vs_new_leaf_on_same_item_conflicts/0,
      fun delete_vs_sibling_item_both_commit/0,
      fun both_delete_same_item/0,
      fun conflict_leaves_txn_alive/0,
      fun rollback_after_concurrent_commit_conflicts/0]}.

%%--------------------------------------------------------------------
%% JSON file
%%--------------------------------------------------------------------
json_test_() ->
    {foreach, fun() -> setup(json, ?J_DIR) end,
     fun(_) -> teardown(json, ?J_DIR) end,
     [fun disjoint_edits_both_commit/0,
      fun same_leaf_second_conflicts/0,
      fun different_leaves_same_item_merge/0]}.

%%--------------------------------------------------------------------
%% sys.config
%%--------------------------------------------------------------------
sys_config_test_() ->
    {foreach, fun() -> setup(sys_config, ?S_DIR) end,
     fun(_) -> teardown(sys_config, ?S_DIR) end,
     [fun disjoint_edits_both_commit/0,
      fun same_leaf_second_conflicts/0,
      fun different_leaves_same_item_merge/0,
      fun unmatched_survives_disjoint_commits/0,
      fun unmatched_survives_conflict/0]}.

%%--------------------------------------------------------------------
%% Cases
%%--------------------------------------------------------------------
disjoint_edits_both_commit() ->
    TxnA = mgmtd:txn_new(),
    TxnB = mgmtd:txn_new(),
    {ok, _} = txn_set_commit(TxnA, ["interface", "speed", "1GbE"]),
    {ok, _} = txn_set_commit(TxnB, ["server", "servers", {"web1"}, "port", "81"]),
    ?assertEqual({ok, "1GbE"}, mgmtd:lookup(["interface", "speed"])),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"web1"}, "port"])).

same_leaf_second_conflicts() ->
    TxnA = mgmtd:txn_new(),
    TxnB = mgmtd:txn_new(),
    {ok, _} = txn_set_commit(TxnA, ["server", "servers", {"web1"}, "port", "81"]),
    ?assertMatch({error, {conflict, _}},
                 txn_set_commit(TxnB, ["server", "servers", {"web1"}, "port", "82"])),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"web1"}, "port"])).

same_value_second_is_ok() ->
    TxnA = mgmtd:txn_new(),
    TxnB = mgmtd:txn_new(),
    {ok, _} = txn_set_commit(TxnA, ["server", "servers", {"web1"}, "port", "81"]),
    {ok, _} = txn_set_commit(TxnB, ["server", "servers", {"web1"}, "port", "81"]),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"web1"}, "port"])).

different_leaves_same_item_merge() ->
    TxnA = mgmtd:txn_new(),
    TxnB = mgmtd:txn_new(),
    {ok, _} = txn_set_commit(TxnA, ["server", "servers", {"web1"}, "port", "81"]),
    {ok, _} = txn_set_commit(TxnB, ["server", "servers", {"web1"}, "host", "10.0.0.1"]),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"web1"}, "port"])),
    ?assertEqual({ok, {10, 0, 0, 1}},
                 mgmtd:lookup(["server", "servers", {"web1"}, "host"])).

delete_vs_set_same_item_conflicts() ->
    {ok, Seed} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    ok = mgmtd:txn_exit(Seed),
    TxnA = mgmtd:txn_new(),
    TxnB = mgmtd:txn_new(),
    {ok, _} = txn_delete_commit(TxnA, ["server", "servers", {"web1"}]),
    ?assertMatch({error, {conflict, _}},
                 txn_set_commit(TxnB, ["server", "servers", {"web1"}, "port", "99"])),
    ?assertEqual({ok, []}, mgmtd:lookup(["server", "servers"])).

delete_vs_new_leaf_on_same_item_conflicts() ->
    {ok, Seed} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    ok = mgmtd:txn_exit(Seed),
    TxnDel = mgmtd:txn_new(),
    TxnSet = mgmtd:txn_new(),
    {ok, _} = txn_set_commit(TxnSet, ["server", "servers", {"web1"}, "host", "10.0.0.1"]),
    ?assertMatch({error, {conflict, _}},
                 txn_delete_commit(TxnDel, ["server", "servers", {"web1"}])),
    ?assertEqual({ok, {10, 0, 0, 1}},
                 mgmtd:lookup(["server", "servers", {"web1"}, "host"])).

delete_vs_sibling_item_both_commit() ->
    {ok, Seed} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    ok = mgmtd:txn_exit(Seed),
    TxnDel = mgmtd:txn_new(),
    TxnAdd = mgmtd:txn_new(),
    {ok, _} = txn_delete_commit(TxnDel, ["server", "servers", {"web1"}]),
    {ok, _} = txn_set_commit(TxnAdd, ["server", "servers", {"web2"}, "port", "82"]),
    ?assertEqual({ok, [{"web2"}]}, mgmtd:lookup(["server", "servers"])),
    ?assertEqual({ok, 82}, mgmtd:lookup(["server", "servers", {"web2"}, "port"])).

both_delete_same_item() ->
    {ok, Seed} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    ok = mgmtd:txn_exit(Seed),
    TxnA = mgmtd:txn_new(),
    TxnB = mgmtd:txn_new(),
    {ok, _} = txn_delete_commit(TxnA, ["server", "servers", {"web1"}]),
    {ok, _} = txn_delete_commit(TxnB, ["server", "servers", {"web1"}]),
    ?assertEqual({ok, []}, mgmtd:lookup(["server", "servers"])).

conflict_leaves_txn_alive() ->
    TxnA = mgmtd:txn_new(),
    TxnB = mgmtd:txn_new(),
    {ok, _} = txn_set_commit(TxnA, ["server", "servers", {"web1"}, "port", "81"]),
    {ok, TxnB1} = txn_set(TxnB, ["server", "servers", {"web1"}, "port", "82"]),
    ?assertMatch({error, {conflict, _}}, mgmtd:txn_commit(TxnB1)),
    %% Session still holds its own edit; running is unchanged.
    {ok, Show} = mgmtd:txn_show(TxnB1, []),
    Server = proplists:get_value("server", Show),
    Servers = proplists:get_value("servers", Server),
    Item = proplists:get_value({"web1"}, Servers),
    ?assertEqual({value, 82}, proplists:get_value("port", Item)),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"web1"}, "port"])),
    ok = mgmtd:txn_exit(TxnB1).

rollback_after_concurrent_commit_conflicts() ->
    {ok, Seed} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    ok = mgmtd:txn_exit(Seed),
    TxnB = mgmtd:txn_new(),
    {ok, _} = commit_set(["server", "servers", {"web1"}, "port", "82"]),
    {ok, TxnB1} = mgmtd:txn_rollback(TxnB, 1),
    ?assertMatch({error, {conflict, _}}, mgmtd:txn_commit(TxnB1)),
    ?assertEqual({ok, 82}, mgmtd:lookup(["server", "servers", {"web1"}, "port"])),
    ok = mgmtd:txn_exit(TxnB1).

unmatched_survives_disjoint_commits() ->
    ok = load_unmatched(?S_DIR),
    TxnA = mgmtd:txn_new(),
    TxnB = mgmtd:txn_new(),
    {ok, _} = txn_set_commit(TxnA, ["interface", "speed", "1GbE"]),
    {ok, _} = txn_set_commit(TxnB, ["server", "servers", {"web1"}, "port", "81"]),
    {ok, [Term]} = file:consult(filename:join(?S_DIR, "sys.config")),
    ?assertEqual(info, proplists:get_value(logger_level,
                                           proplists:get_value(kernel, Term))),
    ?assertEqual({tuple, value},
                 proplists:get_value(orphan, proplists:get_value(default, Term))),
    ?assertEqual({ok, "1GbE"}, mgmtd:lookup(["interface", "speed"])),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"web1"}, "port"])),
    ?assertEqual({error, unknown_schema_path}, mgmtd:lookup(["orphan"])).

unmatched_survives_conflict() ->
    ok = load_unmatched(?S_DIR),
    TxnA = mgmtd:txn_new(),
    TxnB = mgmtd:txn_new(),
    {ok, _} = txn_set_commit(TxnA, ["server", "servers", {"web1"}, "port", "81"]),
    ?assertMatch({error, {conflict, _}},
                 txn_set_commit(TxnB, ["server", "servers", {"web1"}, "port", "82"])),
    {ok, [Term]} = file:consult(filename:join(?S_DIR, "sys.config")),
    ?assertEqual(info, proplists:get_value(logger_level,
                                           proplists:get_value(kernel, Term))),
    ?assertEqual({tuple, value},
                 proplists:get_value(orphan, proplists:get_value(default, Term))),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"web1"}, "port"])).

%%--------------------------------------------------------------------
%% Setup
%%--------------------------------------------------------------------
setup(Backend, Dir) ->
    start_mgmtd(),
    ok = mgmtd:remove_schema(),
    ok = mgmtd_cfg_db:remove_db(Dir, [{backend, Backend}]),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ok = mgmtd_cfg_db:init(Dir, [{backend, Backend}]),
    ok.

teardown(Backend, Dir) ->
    ok = mgmtd:remove_schema(),
    ok = mgmtd_cfg_db:remove_db(Dir, [{backend, Backend}]),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

load_unmatched(Dir) ->
    Term = [{kernel, [{logger_level, info}]},
            {default, [{orphan, {tuple, value}}]}],
    ok = mgmtd_cfg_db:remove_db(Dir, [{backend, sys_config}]),
    ok = filelib:ensure_dir(filename:join(Dir, "sys.config")),
    ok = file:write_file(filename:join(Dir, "sys.config"),
                         mgmtd_cfg_db_sys_config:format_consult(Term)),
    mgmtd_cfg_db:init(Dir, [{backend, sys_config}]).

commit_set(Path) ->
    txn_set_commit(mgmtd:txn_new(), Path).

txn_set(Txn, Path) ->
    {ok, SchemaPath} = mgmtd_schema:lookup_path(Path),
    mgmtd:txn_set(Txn, SchemaPath).

txn_set_commit(Txn, Path) ->
    {ok, Txn2} = txn_set(Txn, Path),
    mgmtd:txn_commit(Txn2).

txn_delete_commit(Txn, Path) ->
    {ok, SchemaPath} = mgmtd_schema:lookup_path(Path),
    {ok, Txn2} = mgmtd:txn_delete(Txn, SchemaPath),
    mgmtd:txn_commit(Txn2).
