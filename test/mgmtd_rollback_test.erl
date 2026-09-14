-module(mgmtd_rollback_test).

-include_lib("eunit/include/eunit.hrl").
-include("../src/mgmtd_schema.hrl").

-define(MNESIA_DIR, "test_db_rollback_mnesia").
-define(SYS_DIR, "test_db_rollback_sys").
-define(JSON_DIR, "test_db_rollback_json").
-define(CAP_DIR, "test_db_rollback_cap").
-define(OFF_DIR, "test_db_rollback_off").
-define(ORD_DIR, "test_db_rollback_ordered").
-define(ORD_SYS_DIR, "test_db_rollback_ordered_sys").

%%--------------------------------------------------------------------
%% Mnesia
%%--------------------------------------------------------------------
mnesia_test_() ->
    {foreach, fun() -> setup(mnesia, ?MNESIA_DIR, 10) end,
     fun(_) -> teardown(mnesia, ?MNESIA_DIR) end,
     [fun first_commit_writes_zero/0,
      fun noop_commit_does_not_rotate/0,
      fun second_commit_shifts/0,
      fun restore_previous/0,
      fun one_shot_rollback/0,
      fun unknown_index/0,
      fun rollback_zero_is_noop/0,
      fun subscribers_see_restore/0]}.

%%--------------------------------------------------------------------
%% sys.config
%%--------------------------------------------------------------------
sys_config_test_() ->
    {foreach, fun() -> setup(sys_config, ?SYS_DIR, 10) end,
     fun(_) -> teardown(sys_config, ?SYS_DIR) end,
     [fun first_commit_writes_zero/0,
      fun second_commit_shifts/0,
      fun restore_previous/0]}.

%%--------------------------------------------------------------------
%% JSON file
%%--------------------------------------------------------------------
json_test_() ->
    {foreach, fun() -> setup(json, ?JSON_DIR, 10) end,
     fun(_) -> teardown(json, ?JSON_DIR) end,
     [fun first_commit_writes_zero/0,
      fun second_commit_shifts/0,
      fun restore_previous/0]}.

%%--------------------------------------------------------------------
%% count / disable
%%--------------------------------------------------------------------
cap_test_() ->
    {setup, fun() -> setup(mnesia, ?CAP_DIR, 2) end,
     fun(_) -> teardown(mnesia, ?CAP_DIR) end,
     fun drop_past_count/0}.

disabled_test_() ->
    {setup, fun() -> setup(mnesia, ?OFF_DIR, 0) end,
     fun(_) -> teardown(mnesia, ?OFF_DIR) end,
     fun disabled_writes_nothing/0}.

%%--------------------------------------------------------------------
%% ordered-by user
%%--------------------------------------------------------------------
ordered_mnesia_test_() ->
    {foreach, fun() -> setup_ordered(mnesia, ?ORD_DIR) end,
     fun(_) -> teardown(mnesia, ?ORD_DIR) end,
     [fun rollback_file_stores_user_order/0,
      fun rollback_show_preserves_user_order/0,
      fun restore_previous_restores_user_order/0,
      fun rollback_file_stores_leaf_list_order/0]}.

ordered_sys_config_test_() ->
    {foreach, fun() -> setup_ordered(sys_config, ?ORD_SYS_DIR) end,
     fun(_) -> teardown(sys_config, ?ORD_SYS_DIR) end,
     [fun rollback_show_preserves_user_order/0,
      fun restore_previous_restores_user_order/0]}.

%%--------------------------------------------------------------------
%% Cases
%%--------------------------------------------------------------------
first_commit_writes_zero() ->
    ?assertEqual([], mgmtd:rollback_list()),
    {ok, _} = commit_set(["server", "servers", {"a"}, "port", "81"]),
    ?assertEqual([], mgmtd:rollback_list()),
    ?assert(filelib:is_regular(rb_file(0))),
    {ok, Tree} = mgmtd:rollback_show(0),
    {ok, Running} = mgmtd:txn_show(undefined, []),
    ?assertEqual(Running, Tree).

noop_commit_does_not_rotate() ->
    {ok, _} = commit_set(["server", "servers", {"a"}, "port", "81"]),
    ?assertEqual([], mgmtd:rollback_list()),
    {ok, _} = mgmtd:txn_commit(mgmtd:txn_new()),
    ?assertEqual([], mgmtd:rollback_list()),
    ?assertNot(filelib:is_regular(rb_file(1))).

second_commit_shifts() ->
    {ok, _} = commit_set(["server", "servers", {"a"}, "port", "81"]),
    {ok, First} = mgmtd:rollback_show(0),
    {ok, _} = commit_set(["server", "servers", {"a"}, "port", "82"]),
    List = mgmtd:rollback_list(),
    ?assertEqual([1], [I || {I, _} <- List]),
    [{1, #{time := T}}] = List,
    ?assert(is_integer(T)),
    {ok, Prev} = mgmtd:rollback_show(1),
    {ok, Now} = mgmtd:rollback_show(0),
    ?assertEqual(First, Prev),
    ?assertNotEqual(First, Now),
    ?assertEqual({ok, 82}, mgmtd:lookup(["server", "servers", {"a"}, "port"])).

restore_previous() ->
    {ok, _} = commit_set(["server", "servers", {"a"}, "port", "81"]),
    {ok, _} = commit_set(["server", "servers", {"a"}, "port", "82"]),
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = mgmtd:txn_rollback(Txn, 1),
    {ok, _} = mgmtd:txn_commit(Txn2),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"a"}, "port"])).

one_shot_rollback() ->
    {ok, _} = commit_set(["server", "servers", {"a"}, "port", "81"]),
    {ok, _} = commit_set(["server", "servers", {"b"}, "port", "90"]),
    ok = mgmtd:rollback(1),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"a"}, "port"])),
    ?assertEqual({ok, [{"a"}]}, mgmtd:lookup(["server", "servers"])).

unknown_index() ->
    {ok, _} = commit_set(["server", "servers", {"a"}, "port", "81"]),
    ?assertEqual({error, {unknown_rollback, 7}}, mgmtd:txn_rollback(mgmtd:txn_new(), 7)),
    ?assertEqual({error, {unknown_rollback, 7}}, mgmtd:rollback_show(7)).

rollback_zero_is_noop() ->
    {ok, _} = commit_set(["server", "servers", {"a"}, "port", "81"]),
    ?assertEqual([], mgmtd:rollback_list()),
    ok = mgmtd:rollback(0),
    ?assertEqual([], mgmtd:rollback_list()),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"a"}, "port"])).

subscribers_see_restore() ->
    {ok, _} = commit_set(["server", "servers", {"a"}, "port", "81"]),
    {ok, Ref} = mgmtd:subscribe(["server", "servers"], self()),
    _Snap = recv_change(Ref),
    {ok, _} = commit_set(["server", "servers", {"a"}, "port", "82"]),
    ?assertEqual([{set, ["server", "servers", {"a"}, "port"], 82}],
                 recv_change(Ref)),
    ok = mgmtd:rollback(1),
    ?assertEqual([{set, ["server", "servers", {"a"}, "port"], 81}],
                 recv_change(Ref)).

drop_past_count() ->
    {ok, _} = commit_set(["server", "servers", {"a"}, "port", "81"]),
    {ok, _} = commit_set(["server", "servers", {"a"}, "port", "82"]),
    {ok, _} = commit_set(["server", "servers", {"a"}, "port", "83"]),
    ?assertEqual([1], [I || {I, _} <- mgmtd:rollback_list()]),
    ?assertNot(filelib:is_regular(filename:join([?CAP_DIR, "rollback", "rollback.2"]))),
    ok = mgmtd:rollback(1),
    ?assertEqual({ok, 82}, mgmtd:lookup(["server", "servers", {"a"}, "port"])).

disabled_writes_nothing() ->
    {ok, _} = commit_set(["server", "servers", {"a"}, "port", "81"]),
    ?assertNot(filelib:is_dir(filename:join(?OFF_DIR, "rollback"))),
    ?assertEqual({error, {rollback_disabled, 1}},
                 mgmtd:txn_rollback(mgmtd:txn_new(), 1)).

rollback_file_stores_user_order() ->
    commit_rules([{"z", "drop"}, {"a", "permit"}, {"m", "drop"}]),
    ?assertEqual([{"z"}, {"a"}, {"m"}], rule_keys()),
    {ok, #{rows := Rows}} = consult_rollback(0),
    List = lists:keyfind(["ord", "acl", "rule"], #cfg.path, Rows),
    ?assertMatch(#cfg{node_type = list, value = {ordered, [{"z"}, {"a"}, {"m"}]}},
                 List).

rollback_show_preserves_user_order() ->
    commit_rules([{"z", "drop"}, {"a", "permit"}, {"m", "drop"}]),
    {ok, Tree0} = mgmtd:rollback_show(0),
    {ok, Running} = mgmtd:txn_show(undefined, []),
    ?assertEqual(Running, Tree0),
    ?assertEqual([{"z"}, {"a"}, {"m"}], rule_keys_from_tree(Tree0)),
    move_rule_first({"a"}),
    ?assertEqual([{"a"}, {"z"}, {"m"}], rule_keys()),
    {ok, Prev} = mgmtd:rollback_show(1),
    {ok, Now} = mgmtd:rollback_show(0),
    ?assertEqual([{"z"}, {"a"}, {"m"}], rule_keys_from_tree(Prev)),
    ?assertEqual([{"a"}, {"z"}, {"m"}], rule_keys_from_tree(Now)).

restore_previous_restores_user_order() ->
    commit_rules([{"z", "drop"}, {"a", "permit"}, {"m", "drop"}]),
    move_rule_first({"a"}),
    ?assertEqual([{"a"}, {"z"}, {"m"}], rule_keys()),
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = mgmtd:txn_rollback(Txn, 1),
    ?assertEqual([{"z"}, {"a"}, {"m"}],
                 mgmtd:list_keys(Txn2, ["ord", "acl", "rule"], '$1')),
    {ok, _} = mgmtd:txn_commit(Txn2),
    ?assertEqual([{"z"}, {"a"}, {"m"}], rule_keys()).

rollback_file_stores_leaf_list_order() ->
    {ok, Tags} = mgmtd_schema:lookup_path(["ord", "acl", "tag", ["c", "a", "b"]]),
    {ok, _} = mgmtd:txn_commit(element(2, mgmtd:txn_set(mgmtd:txn_new(), Tags))),
    ?assertEqual({ok, ["c", "a", "b"]}, mgmtd:lookup(["ord", "acl", "tag"])),
    {ok, #{rows := Rows}} = consult_rollback(0),
    LL = lists:keyfind(["ord", "acl", "tag"], #cfg.path, Rows),
    ?assertMatch(#cfg{node_type = leaf_list, value = ["c", "a", "b"]}, LL),
    {ok, Move} = mgmtd:txn_move(mgmtd:txn_new(),
                                ["ord", "acl", "tag", {"a"}], first),
    {ok, _} = mgmtd:txn_commit(Move),
    ?assertEqual({ok, ["a", "c", "b"]}, mgmtd:lookup(["ord", "acl", "tag"])),
    {ok, Txn} = mgmtd:txn_rollback(mgmtd:txn_new(), 1),
    {ok, _} = mgmtd:txn_commit(Txn),
    ?assertEqual({ok, ["c", "a", "b"]}, mgmtd:lookup(["ord", "acl", "tag"])).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------
setup(Backend, Dir, Count) ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(Dir, [{backend, Backend}]),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ok = mgmtd_cfg_db:init(Dir, [{backend, Backend}, {rollback, Count}]),
    ok.

setup_ordered(Backend, Dir) ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(Dir, [{backend, Backend}]),
    ok = mgmtd:load_yang_module("test/yang/example-ordered.yang"),
    ok = mgmtd_cfg_db:init(Dir, [{backend, Backend}, {rollback, 10}]),
    ok.

commit_rules(Terms) ->
    Txn = lists:foldl(
            fun({Name, Action}, Acc) ->
                    {ok, SP} = mgmtd_schema:lookup_path(
                                 ["ord", "acl", "rule", {Name}, "action", Action]),
                    {ok, Acc1} = mgmtd:txn_set(Acc, SP),
                    Acc1
            end, mgmtd:txn_new(), Terms),
    {ok, _} = mgmtd:txn_commit(Txn).

move_rule_first(Key) ->
    {ok, SP} = mgmtd_schema:lookup_path(["ord", "acl", "rule", Key]),
    {ok, Txn} = mgmtd:txn_move(mgmtd:txn_new(), SP, first),
    {ok, _} = mgmtd:txn_commit(Txn).

rule_keys() ->
    [K || K <- mgmtd_cfg_db:list_keys(["ord", "acl", "rule"]), is_tuple(K)].

rule_keys_from_tree(Tree) ->
    Ord = proplists:get_value("ord", Tree),
    Acl = proplists:get_value("acl", Ord),
    Rules = proplists:get_value("rule", Acl),
    [K || {K, _} <- Rules].

consult_rollback(N) ->
    File = rb_file(N),
    {ok, [{mgmtd_rollback, 1, _Meta, Maps}]} = file:consult(File),
    {ok, #{rows => [map_to_cfg(M) || M <- Maps]}}.

map_to_cfg(#{path := Path, node_type := Type} = M) ->
    #cfg{path = Path,
         name = maps:get(name, M, lists:last(Path)),
         node_type = Type,
         value = maps:get(value, M, undefined)}.

teardown(Backend, Dir) ->
    lists:foreach(fun({{_Path, _Pid, Ref}, _}) ->
                          try mgmtd_cfg_server:unsubscribe(Ref)
                          catch _:_ -> ok
                          end
                  end, mgmtd_cfg_server:subscriptions()),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(Dir, [{backend, Backend}]),
    flush(),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

commit_set(Path) ->
    Txn = mgmtd:txn_new(),
    {ok, SP} = mgmtd_schema:lookup_path(Path),
    {ok, Txn2} = mgmtd:txn_set(Txn, SP),
    mgmtd:txn_commit(Txn2).

rb_file(N) ->
    [{_, Loc}] = ets:lookup(mgmtd_meta, db_location),
    filename:join([Loc, "rollback", "rollback." ++ integer_to_list(N)]).

recv_change(Ref) ->
    receive
        {config_change, Ref, Ops} ->
            Ops
    after 1000 ->
            error({timeout, config_change, Ref})
    end.

flush() ->
    receive
        {config_change, _, _} ->
            flush()
    after 0 ->
            ok
    end.
