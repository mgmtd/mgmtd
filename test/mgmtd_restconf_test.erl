%%%-------------------------------------------------------------------
%%% @doc RESTCONF HTTP listener and discovery tests.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_test).

-include_lib("eunit/include/eunit.hrl").

default_port_test() ->
    ?assertEqual(8008, mgmtd_restconf:default_port()).

config_test_() ->
    {setup, fun save_env/0, fun restore_env/1,
     [fun boolean_false_disables/0,
      fun disabled_does_not_listen/0,
      fun port_from_config/0]}.

listener_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun host_meta_advertises_restconf/0,
      fun options_and_head/0,
      fun api_root_is_yang_json/0,
      fun yang_library_version/0,
      fun modules_state_includes_builtins/0,
      fun operations_is_empty/0,
      fun data_root_has_yang_library/0,
      fun xml_accept_is_not_acceptable/0,
      fun unknown_path_is_not_found/0]}.

setup() ->
    Prev = save_env(),
    _ = application:load(mgmtd),
    ok = application:set_env(mgmtd, restconf, [{enabled, true}, {port, 0}]),
    ok = mgmtd_restconf:start(),
    {ok, _} = application:ensure_all_started(inets),
    Prev.

teardown(Prev) ->
    restore_env(Prev).

save_env() ->
    ok = mgmtd_restconf:stop(),
    application:get_env(mgmtd, restconf).

restore_env(Prev) ->
    ok = mgmtd_restconf:stop(),
    case Prev of
        undefined ->
            application:unset_env(mgmtd, restconf);
        {ok, Val} ->
            application:set_env(mgmtd, restconf, Val)
    end.

boolean_false_disables() ->
    ok = application:set_env(mgmtd, restconf, false),
    ?assertEqual(false, mgmtd_restconf:enabled()).

disabled_does_not_listen() ->
    ok = application:set_env(mgmtd, restconf, [{enabled, false}, {port, 0}]),
    ?assertEqual(false, mgmtd_restconf:enabled()),
    ?assertEqual(ok, mgmtd_restconf:start()),
    ?assertError(_, mgmtd_restconf:port()).

port_from_config() ->
    ok = application:set_env(mgmtd, restconf, [{enabled, true}, {port, 0}]),
    ?assertEqual(true, mgmtd_restconf:enabled()),
    ?assertEqual(ok, mgmtd_restconf:start()),
    Port = mgmtd_restconf:port(),
    ?assert(is_integer(Port) andalso Port > 0),
    ok = mgmtd_restconf:stop().

host_meta_advertises_restconf() ->
    {Code, Headers, Body} = http_get("/.well-known/host-meta"),
    ?assertEqual(200, Code),
    ?assertEqual("application/xrd+xml",
                 proplists:get_value("content-type", Headers)),
    ?assert(is_substring("rel='restconf'", Body)),
    ?assert(is_substring("href='/restconf'", Body)).

api_root_is_yang_json() ->
    {Code, Headers, Body} = http_get("/restconf"),
    ?assertEqual(200, Code),
    ?assertEqual("application/yang-data+json",
                 proplists:get_value("content-type", Headers)),
    #{<<"ietf-restconf:restconf">> := Root} = json:decode(Body),
    ?assertMatch(#{<<"data">> := #{},
                   <<"operations">> := #{},
                   <<"yang-library-version">> := <<"2016-06-21">>},
                 Root).

yang_library_version() ->
    {Code, _, Body} = http_get("/restconf/yang-library-version"),
    ?assertEqual(200, Code),
    ?assertEqual(#{<<"ietf-restconf:yang-library-version">> => <<"2016-06-21">>},
                 json:decode(Body)).

modules_state_includes_builtins() ->
    {Code, _, Body} = http_get("/restconf/data/ietf-yang-library:modules-state"),
    ?assertEqual(200, Code),
    #{<<"ietf-yang-library:modules-state">> := State} = json:decode(Body),
    #{<<"module-set-id">> := Id, <<"module">> := Mods} = State,
    ?assert(is_binary(Id) andalso byte_size(Id) > 0),
    Names = [maps:get(<<"name">>, M) || M <- Mods],
    ?assert(lists:member(<<"ietf-yang-library">>, Names)),
    ?assert(lists:member(<<"ietf-restconf">>, Names)).

operations_is_empty() ->
    {Code, _, Body} = http_get("/restconf/operations"),
    ?assertEqual(200, Code),
    ?assertEqual(#{<<"ietf-restconf:operations">> => #{}}, json:decode(Body)).

data_root_has_yang_library() ->
    {Code, Headers, Body} = http_get("/restconf/data"),
    ?assertEqual(200, Code),
    ?assertEqual("application/yang-data+json",
                 proplists:get_value("content-type", Headers)),
    #{<<"ietf-yang-library:modules-state">> := State} = json:decode(Body),
    ?assert(is_map(State)).

xml_accept_is_not_acceptable() ->
    {Code, _, Body} =
        http_get("/restconf", [{"Accept", "application/yang-data+xml"}]),
    ?assertEqual(406, Code),
    #{<<"ietf-restconf:errors">> := #{<<"error">> := [Err]}} = json:decode(Body),
    ?assertEqual(<<"operation-not-supported">>, maps:get(<<"error-tag">>, Err)).

unknown_path_is_not_found() ->
    {Code, _, _} = http_get("/"),
    ?assertEqual(404, Code).

options_and_head() ->
    {OptCode, OptHdrs, _} = http_req(options, "/restconf/data", []),
    ?assertEqual(200, OptCode),
    Allow = proplists:get_value("allow", OptHdrs),
    ?assert(is_list(Allow) andalso string:find(Allow, "GET") =/= nomatch),
    {HeadCode, HeadHdrs, HeadBody} = http_req(head, "/restconf", []),
    ?assertEqual(200, HeadCode),
    ?assertEqual(<<>>, HeadBody),
    ?assertEqual("application/yang-data+json",
                 proplists:get_value("content-type", HeadHdrs)).

http_req(Method, Path, ExtraHdrs) ->
    Url = lists:flatten(
            io_lib:format("http://127.0.0.1:~p~s",
                          [mgmtd_restconf:port(), Path])),
    {ok, {{_, Code, _}, Headers, Body}} =
        httpc:request(Method, {Url, ExtraHdrs}, [{timeout, 2000}],
                      [{body_format, binary}]),
    {Code, Headers, Body}.

http_get(Path) ->
    http_get(Path, []).

http_get(Path, ExtraHdrs) ->
    Url = lists:flatten(
            io_lib:format("http://127.0.0.1:~p~s",
                          [mgmtd_restconf:port(), Path])),
    {ok, {{_, Code, _}, Headers, Body}} =
        httpc:request(get, {Url, ExtraHdrs}, [{timeout, 2000}],
                      [{body_format, binary}]),
    {Code, Headers, Body}.

is_substring(Needle, Haystack) when is_list(Needle), is_binary(Haystack) ->
    binary:match(Haystack, list_to_binary(Needle)) =/= nomatch.
