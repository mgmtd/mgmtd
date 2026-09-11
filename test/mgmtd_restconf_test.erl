%%%-------------------------------------------------------------------
%%% @doc RESTCONF HTTP listener and discovery tests.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_test).

-include_lib("eunit/include/eunit.hrl").

default_port_test() ->
    ?assertEqual(8008, mgmtd_restconf:default_port()).

listener_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun host_meta_advertises_restconf/0,
      fun api_root_is_yang_json/0,
      fun yang_library_version/0,
      fun modules_state_includes_builtins/0,
      fun operations_is_empty/0,
      fun data_root_not_implemented/0,
      fun xml_accept_is_not_acceptable/0,
      fun unknown_path_is_not_found/0]}.

setup() ->
    Prev = application:get_env(mgmtd, restconf_port),
    ok = application:set_env(mgmtd, restconf_port, 0),
    ok = mgmtd_restconf:start(),
    {ok, _} = application:ensure_all_started(inets),
    Prev.

teardown(Prev) ->
    ok = mgmtd_restconf:stop(),
    case Prev of
        undefined ->
            application:unset_env(mgmtd, restconf_port);
        {ok, Port} ->
            application:set_env(mgmtd, restconf_port, Port)
    end.

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

data_root_not_implemented() ->
    {Code, Headers, Body} = http_get("/restconf/data"),
    ?assertEqual(501, Code),
    ?assertEqual("application/yang-data+json",
                 proplists:get_value("content-type", Headers)),
    #{<<"ietf-restconf:errors">> := #{<<"error">> := [Err]}} = json:decode(Body),
    ?assertEqual(<<"operation-not-supported">>, maps:get(<<"error-tag">>, Err)).

xml_accept_is_not_acceptable() ->
    {Code, _, Body} =
        http_get("/restconf", [{"Accept", "application/yang-data+xml"}]),
    ?assertEqual(406, Code),
    #{<<"ietf-restconf:errors">> := #{<<"error">> := [Err]}} = json:decode(Body),
    ?assertEqual(<<"operation-not-supported">>, maps:get(<<"error-tag">>, Err)).

unknown_path_is_not_found() ->
    {Code, _, _} = http_get("/"),
    ?assertEqual(404, Code).

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
