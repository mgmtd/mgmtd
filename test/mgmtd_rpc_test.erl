%%%-------------------------------------------------------------------
%%% @doc Erlang API for YANG rpc / action.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_rpc_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/mgmtd.hrl").

-define(DB, "test_db_rpc").

rpc_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun echo_and_add/0,
      fun restart_empty/0,
      fun missing_mandatory/0,
      fun unknown_rpc/0,
      fun action_needs_instance/0,
      fun action_on_item/0,
      fun function_schema_rpc/0]}.

setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-rpc.yang",
                                #{callback => mgmtd_test_rpc}),
    ok = mgmtd_cfg_db:init(?DB, [{backend, mnesia}]),
    ok.

teardown(_) ->
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB, [{backend, mnesia}]),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

echo_and_add() ->
    {ok, #{"out" := "echo:hi"}} = mgmtd:rpc(["rpc", "echo"], #{"in" => "hi"}),
    {ok, #{"sum" := 5}} = mgmtd:rpc(["rpc", "add"], #{"a" => 2, "b" => 3}).

restart_empty() ->
    {ok, empty} = mgmtd:rpc(["rpc", "restart"], #{}).

missing_mandatory() ->
    {error, #{tag := <<"missing-element">>}} =
        mgmtd:rpc(["rpc", "add"], #{"a" => 1}).

unknown_rpc() ->
    {error, #{http := 404}} = mgmtd:rpc(["rpc", "nope"], #{}).

action_needs_instance() ->
    {error, #{http := 404}} =
        mgmtd:action(["rpc", "box", "items", {"x"}, "reset"], #{}).

action_on_item() ->
    {ok, P} = mgmtd_schema:lookup_path(["rpc", "box", "items", {"x"}, "name", "x"]),
    {ok, _} = mgmtd:txn_commit(element(2, mgmtd:txn_set(mgmtd:txn_new(), P))),
    {ok, #{"state" := "reset:x"}} =
        mgmtd:action(["rpc", "box", "items", {"x"}, "reset"], #{}).

function_schema_rpc() ->
    ok = mgmtd:load_function_schema(
           fun() ->
                   [#rpc{name = "ping",
                         callback = mgmtd_test_rpc,
                         output = fun() ->
                                          [#leaf{name = "out", type = string}]
                                  end}]
           end,
           #{namespace => fnrpc}),
    try
        %% mgmtd_test_rpc does not handle ["fnrpc","ping"]; expect unknown_rpc
        {error, #{tag := <<"operation-failed">>}} =
            mgmtd:rpc(["fnrpc", "ping"], #{}),
        Names = [maps:get(name, R) || R <- mgmtd_schema:rpcs(),
                                      maps:get(ns, R) =:= fnrpc],
        ?assertEqual(["ping"], Names)
    after
        mgmtd:remove_schema(fnrpc)
    end.