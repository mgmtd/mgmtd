%%%-------------------------------------------------------------------
%%% @doc RESTCONF HTTP Basic auth.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_auth_test).

-include_lib("eunit/include/eunit.hrl").

auth_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun missing_creds_are_unauthorized/0,
      fun bad_password_is_unauthorized/0,
      fun good_creds_read/0,
      fun read_only_cannot_write/0,
      fun admin_can_options/0,
      fun host_meta_stays_open/0]}.

setup() ->
    PrevRest = save_restconf(),
    PrevAaa = application:get_env(mgmtd, aaa),
    _ = application:load(mgmtd),
    ok = application:set_env(mgmtd, restconf, [{enabled, true}, {port, 0}]),
    ok = application:set_env(
           mgmtd, aaa,
           [{users, [{"alice", admin, "secret"},
                     {"bob", read_only, "guest"}]}]),
    ok = mgmtd_restconf:start(),
    {ok, _} = application:ensure_all_started(inets),
    {PrevRest, PrevAaa}.

teardown({PrevRest, PrevAaa}) ->
    restore_restconf(PrevRest),
    case PrevAaa of
        undefined ->
            application:unset_env(mgmtd, aaa);
        {ok, Val} ->
            application:set_env(mgmtd, aaa, Val)
    end.

save_restconf() ->
    ok = mgmtd_restconf:stop(),
    application:get_env(mgmtd, restconf).

restore_restconf(Prev) ->
    ok = mgmtd_restconf:stop(),
    case Prev of
        undefined ->
            application:unset_env(mgmtd, restconf);
        {ok, Val} ->
            application:set_env(mgmtd, restconf, Val)
    end.

missing_creds_are_unauthorized() ->
    {Code, Headers, Body} = http_req(get, "/restconf", []),
    ?assertEqual(401, Code),
    ?assert(is_basic_challenge(proplists:get_value("www-authenticate", Headers))),
    #{<<"ietf-restconf:errors">> := #{<<"error">> := [Err]}} =
        mgmtd_json:decode(Body),
    ?assertEqual(<<"access-denied">>, maps:get(<<"error-tag">>, Err)).

bad_password_is_unauthorized() ->
    {Code, Headers, _} = http_req(get, "/restconf", [basic("alice", "wrong")]),
    ?assertEqual(401, Code),
    ?assert(is_basic_challenge(proplists:get_value("www-authenticate", Headers))).

good_creds_read() ->
    {Code, _, Body} = http_req(get, "/restconf", [basic("alice", "secret")]),
    ?assertEqual(200, Code),
    #{<<"ietf-restconf:restconf">> := _} = mgmtd_json:decode(Body),
    {BobCode, _, _} = http_req(get, "/restconf", [basic("bob", "guest")]),
    ?assertEqual(200, BobCode).

read_only_cannot_write() ->
    {Code, _, Body} =
        http_req(put, "/restconf/data", [basic("bob", "guest")], <<"{}">>),
    ?assertEqual(403, Code),
    #{<<"ietf-restconf:errors">> := #{<<"error">> := [Err]}} =
        mgmtd_json:decode(Body),
    ?assertEqual(<<"access-denied">>, maps:get(<<"error-tag">>, Err)).

admin_can_options() ->
    {Code, _, _} = http_req(options, "/restconf", [basic("alice", "secret")]),
    ?assertEqual(200, Code).

host_meta_stays_open() ->
    {Code, _, Body} = http_req(get, "/.well-known/host-meta", []),
    ?assertEqual(200, Code),
    ?assert(binary:match(Body, <<"rel='restconf'">>) =/= nomatch).

http_req(Method, Path, ExtraHdrs) ->
    http_req(Method, Path, ExtraHdrs, <<>>).

http_req(Method, Path, ExtraHdrs, Body) when Method =:= put;
                                             Method =:= post;
                                             Method =:= patch ->
    Url = url(Path),
    {ok, {{_, Code, _}, Headers, Resp}} =
        httpc:request(Method,
                      {Url, ExtraHdrs, "application/yang-data+json", Body},
                      [{timeout, 2000}], [{body_format, binary}]),
    {Code, Headers, Resp};
http_req(Method, Path, ExtraHdrs, _) ->
    Url = url(Path),
    {ok, {{_, Code, _}, Headers, Resp}} =
        httpc:request(Method, {Url, ExtraHdrs}, [{timeout, 2000}],
                      [{body_format, binary}]),
    {Code, Headers, Resp}.

url(Path) ->
    lists:flatten(
      io_lib:format("http://127.0.0.1:~p~s",
                    [mgmtd_restconf:port(), Path])).

basic(User, Pass) ->
    {"Authorization",
     "Basic " ++ base64:encode_to_string(User ++ ":" ++ Pass)}.

is_basic_challenge(undefined) ->
    false;
is_basic_challenge(Value) ->
    string:find(string:lowercase(Value), "basic") =/= nomatch.
