%%%-------------------------------------------------------------------
%%% @doc Schema snapshot for the Web UI.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ui_schema_test).

-include_lib("eunit/include/eunit.hrl").

snapshot_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun empty_without_schema/0,
      fun default_and_named_prefix/0,
      fun list_keys_and_leaf_types/0,
      fun rpc_operations_paths/0,
      fun http_get_schema/0,
      fun http_head_and_options/0]}.

setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Prev = application:get_env(mgmtd, restconf),
    ok = application:set_env(mgmtd, restconf, [{enabled, true}, {port, 0}]),
    ok = mgmtd_restconf:start(),
    {ok, _} = application:ensure_all_started(inets),
    Prev.

teardown(Prev) ->
    ok = mgmtd_restconf:stop(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    case Prev of
        undefined -> application:unset_env(mgmtd, restconf);
        {ok, Val} -> application:set_env(mgmtd, restconf, Val)
    end.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

empty_without_schema() ->
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ?assertEqual(#{<<"modules">> => []}, mgmtd_ui_schema:snapshot()).

default_and_named_prefix() ->
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                    #{namespace => example}),
    #{<<"modules">> := Mods} = mgmtd_ui_schema:snapshot(),
    Names = [maps:get(<<"name">>, M) || M <- Mods],
    ?assertEqual([<<"default">>, <<"example">>], lists:sort(Names)),
    Default = find(<<"name">>, <<"default">>, Mods),
    Example = find(<<"name">>, <<"example">>, Mods),
    DefChildren = [maps:get(<<"name">>, C) || C <- maps:get(<<"children">>, Default)],
    ?assert(lists:member(<<"server">>, DefChildren)),
    ?assert(lists:member(<<"interface">>, DefChildren)),
    ?assertNot(lists:member(<<"example">>, DefChildren)),
    Server = find(<<"name">>, <<"server">>, maps:get(<<"children">>, Default)),
    ?assertEqual(<<"container">>, maps:get(<<"kind">>, Server)),
    ?assertEqual(<<"/restconf/data/default:server">>, maps:get(<<"path">>, Server)),
    ?assertEqual(<<"default:server">>, maps:get(<<"qname">>, Server)),
    ?assertEqual(true, maps:get(<<"config">>, Server)),
    ExServer = find(<<"name">>, <<"server">>, maps:get(<<"children">>, Example)),
    ?assertEqual(<<"/restconf/data/example:server">>, maps:get(<<"path">>, ExServer)),
    ?assertEqual(<<"example:server">>, maps:get(<<"qname">>, ExServer)),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()).

list_keys_and_leaf_types() ->
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    #{<<"modules">> := [Default]} = mgmtd_ui_schema:snapshot(),
    Server = find(<<"name">>, <<"server">>, maps:get(<<"children">>, Default)),
    Servers = find(<<"name">>, <<"servers">>, maps:get(<<"children">>, Server)),
    ?assertEqual(<<"list">>, maps:get(<<"kind">>, Servers)),
    ?assertEqual([<<"name">>], maps:get(<<"key_names">>, Servers)),
    ?assertEqual(<<"system">>, maps:get(<<"ordered_by">>, Servers)),
    ?assertEqual(<<"/restconf/data/default:server/servers">>,
                 maps:get(<<"path">>, Servers)),
    Port = find(<<"name">>, <<"port">>, maps:get(<<"children">>, Servers)),
    ?assertEqual(<<"leaf">>, maps:get(<<"kind">>, Port)),
    ?assertEqual(<<"/restconf/data/default:server/servers/port">>,
                 maps:get(<<"path">>, Port)),
    ?assertEqual(#{<<"base">> => <<"inet:port-number">>}, maps:get(<<"type">>, Port)),
    ?assertEqual(80, maps:get(<<"default">>, Port)),
    Speed = find(<<"name">>, <<"speed">>,
                 maps:get(<<"children">>,
                          find(<<"name">>, <<"interface">>,
                               maps:get(<<"children">>, Default)))),
    #{<<"base">> := <<"enumeration">>, <<"enum">> := Enums} =
        maps:get(<<"type">>, Speed),
    ?assertEqual(<<"1GbE">>, maps:get(<<"name">>, hd(Enums))),
    Clients = find(<<"name">>, <<"clients">>,
                   maps:get(<<"children">>,
                            find(<<"name">>, <<"client">>,
                                 maps:get(<<"children">>, Default)))),
    ?assertEqual([<<"host">>, <<"port">>], maps:get(<<"key_names">>, Clients)),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()).

rpc_operations_paths() ->
    ok = mgmtd:load_yang_module("test/yang/example-rpc.yang"),
    #{<<"modules">> := Mods} = mgmtd_ui_schema:snapshot(),
    RpcMod = find(<<"name">>, <<"example-rpc">>, Mods),
    Kids = maps:get(<<"children">>, RpcMod),
    Names = [maps:get(<<"name">>, C) || C <- Kids],
    ?assert(lists:member(<<"echo">>, Names)),
    ?assert(lists:member(<<"box">>, Names)),
    Echo = find(<<"name">>, <<"echo">>, Kids),
    ?assertEqual(<<"rpc">>, maps:get(<<"kind">>, Echo)),
    ?assertEqual(<<"/restconf/operations/example-rpc:echo">>,
                 maps:get(<<"path">>, Echo)),
    Input = find(<<"name">>, <<"input">>, maps:get(<<"children">>, Echo)),
    In = find(<<"name">>, <<"in">>, maps:get(<<"children">>, Input)),
    ?assertEqual(<<"leaf">>, maps:get(<<"kind">>, In)),
    Box = find(<<"name">>, <<"box">>, Kids),
    ?assertEqual(<<"container">>, maps:get(<<"kind">>, Box)),
    ?assertEqual(<<"/restconf/data/example-rpc:box">>, maps:get(<<"path">>, Box)),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()).

http_get_schema() ->
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    {Code, Headers, Body} = http_get("/mgmtd/schema"),
    ?assertEqual(200, Code),
    CT = proplists:get_value("content-type", Headers),
    ?assert(is_list(CT) andalso string:prefix(CT, "application/json") =/= nomatch),
    #{<<"modules">> := [Default]} = mgmtd_json:decode(Body),
    true = is_map(Default),
    ?assertEqual(<<"default">>, maps:get(<<"name">>, Default)),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()).

http_head_and_options() ->
    {HCode, Hdrs, HBody} = http_req(head, "/mgmtd/schema", []),
    ?assertEqual(200, HCode),
    ?assertEqual(<<>>, HBody),
    HCT = proplists:get_value("content-type", Hdrs),
    ?assert(is_list(HCT) andalso string:prefix(HCT, "application/json") =/= nomatch),
    {OCode, OHdrs, _} = http_req(options, "/mgmtd/schema", []),
    ?assertEqual(200, OCode),
    Allow = proplists:get_value("allow", OHdrs),
    ?assert(is_list(Allow) andalso string:find(Allow, "GET") =/= nomatch).

find(Key, Val, List) ->
    case [X || X <- List, maps:get(Key, X) =:= Val] of
        [X] -> X;
        Other -> error({find, Key, Val, Other})
    end.

http_req(Method, Path, ExtraHdrs) ->
    Url = lists:flatten(
            io_lib:format("http://127.0.0.1:~p~s",
                          [mgmtd_restconf:port(), Path])),
    {ok, {{_, Code, _}, Headers, Body}} =
        httpc:request(Method, {Url, ExtraHdrs}, [{timeout, 2000}],
                      [{body_format, binary}]),
    {Code, Headers, Body}.

http_get(Path) ->
    http_req(get, Path, []).
