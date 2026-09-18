%%%-------------------------------------------------------------------
%%% @doc RESTCONF operations and nested action POST.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_rpc_test).

-include_lib("eunit/include/eunit.hrl").

-define(DB, "test_db_restconf_rpc").

rpc_http_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun operations_lists_rpcs/0,
      fun get_one_operation/0,
      fun post_restart_204/0,
      fun post_echo/0,
      fun post_add/0,
      fun post_action/0]}.

setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-rpc.yang",
                                #{callback => mgmtd_test_rpc}),
    ok = mgmtd_cfg_db:init(?DB, [{backend, mnesia}]),
    Prev = application:get_env(mgmtd, restconf),
    ok = application:set_env(mgmtd, restconf, [{enabled, true}, {port, 0}]),
    ok = mgmtd_restconf:start(),
    {ok, _} = application:ensure_all_started(inets),
    Prev.

teardown(Prev) ->
    ok = mgmtd_restconf:stop(),
    case Prev of
        undefined -> application:unset_env(mgmtd, restconf);
        {ok, Val} -> application:set_env(mgmtd, restconf, Val)
    end,
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB, [{backend, mnesia}]),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

operations_lists_rpcs() ->
    {Code, _, Body} = http_get("/restconf/operations"),
    ?assertEqual(200, Code),
    #{<<"ietf-restconf:operations">> := Ops} = mgmtd_json:decode(Body),
    ?assertEqual([null], maps:get(<<"example-rpc:echo">>, Ops)),
    ?assertEqual([null], maps:get(<<"example-rpc:restart">>, Ops)),
    ?assertEqual([null], maps:get(<<"example-rpc:add">>, Ops)),
    ?assertEqual(false, maps:is_key(<<"example-rpc:reset">>, Ops)).

get_one_operation() ->
    {Code, _, Body} = http_get("/restconf/operations/example-rpc:echo"),
    ?assertEqual(200, Code),
    ?assertEqual(#{<<"example-rpc:echo">> => [null]}, mgmtd_json:decode(Body)).

post_restart_204() ->
    {Code, _, Body} = http_post("/restconf/operations/example-rpc:restart", #{}),
    ?assertEqual(204, Code),
    ?assertEqual(<<>>, Body).

post_echo() ->
    {Code, _, Body} =
        http_post("/restconf/operations/example-rpc:echo",
                  #{<<"example-rpc:input">> => #{<<"in">> => <<"hi">>}}),
    ?assertEqual(200, Code),
    ?assertEqual(#{<<"example-rpc:output">> => #{<<"out">> => <<"echo:hi">>}},
                 mgmtd_json:decode(Body)).

post_add() ->
    {Code, _, Body} =
        http_post("/restconf/operations/example-rpc:add",
                  #{<<"example-rpc:input">> => #{<<"a">> => 2, <<"b">> => 3}}),
    ?assertEqual(200, Code),
    ?assertEqual(#{<<"example-rpc:output">> => #{<<"sum">> => 5}},
                 mgmtd_json:decode(Body)).

post_action() ->
    {ok, created} =
        mgmtd_restconf_data:put(
          <<"/restconf/data/example-rpc:box/items=x">>,
          #{<<"example-rpc:items">> => [#{<<"name">> => <<"x">>}]}),
    {Code, _, Body} =
        http_post("/restconf/data/example-rpc:box/items=x/reset", #{}),
    ?assertEqual(200, Code),
    ?assertEqual(#{<<"example-rpc:output">> => #{<<"state">> => <<"reset:x">>}},
                 mgmtd_json:decode(Body)).

http_get(Path) ->
    Url = url(Path),
    {ok, {{_, Code, _}, Headers, Body}} =
        httpc:request(get, {Url, []}, [{timeout, 2000}],
                      [{body_format, binary}]),
    {Code, Headers, Body}.

http_post(Path, Map) ->
    Url = url(Path),
    Body = iolist_to_binary(mgmtd_json:encode(Map)),
    {ok, {{_, Code, _}, Headers, Resp}} =
        httpc:request(post,
                      {Url,
                       [{"Content-Type", "application/yang-data+json"}],
                       "application/yang-data+json", Body},
                      [{timeout, 2000}], [{body_format, binary}]),
    {Code, Headers, Resp}.

url(Path) ->
    lists:flatten(io_lib:format("http://127.0.0.1:~p~s",
                                [mgmtd_restconf:port(), Path])).
