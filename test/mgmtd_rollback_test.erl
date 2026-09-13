-module(mgmtd_rollback_test).

-include_lib("eunit/include/eunit.hrl").

-define(MNESIA_DIR, "test_db_rollback_mnesia").
-define(SYS_DIR, "test_db_rollback_sys").
-define(CAP_DIR, "test_db_rollback_cap").
-define(OFF_DIR, "test_db_rollback_off").

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
