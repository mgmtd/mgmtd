%%%-------------------------------------------------------------------
%%% @doc RESTCONF module identity for YANG, JSON Schema, and Erlang schemas.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_yanglib_test).

-include_lib("eunit/include/eunit.hrl").

identity_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun default_function_schema_is_module_default/0,
      fun named_function_schema_uses_prefix_as_module/0,
      fun json_schema_synthesizes_urn/0,
      fun yang_module_name_differs_from_prefix/0,
      fun restconf_module_override/0,
      fun modules_state_lists_all_sources/0]}.

setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok.

teardown(_) ->
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

default_function_schema_is_module_default() ->
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    Info = info(default),
    ?assertEqual("default", maps:get(module, Info)),
    ?assertEqual("urn:mgmtd:default", maps:get(namespace, Info)),
    ?assertEqual(function, maps:get(source, Info)),
    ?assertEqual(undefined, maps:get(revision, Info)),
    ok = mgmtd:remove_schema().

named_function_schema_uses_prefix_as_module() ->
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                    #{namespace => example}),
    Info = info(example),
    ?assertEqual("example", maps:get(module, Info)),
    ?assertEqual("urn:mgmtd:example", maps:get(namespace, Info)),
    ok = mgmtd:remove_schema(example).

json_schema_synthesizes_urn() ->
    ok = mgmtd:load_json_schema("test/json_schema_draft07.json",
                                #{namespace => draft7}),
    Info = info(draft7),
    ?assertEqual("draft7", maps:get(module, Info)),
    ?assertEqual("urn:mgmtd:draft7", maps:get(namespace, Info)),
    ?assertEqual(json, maps:get(source, Info)),
    ok = mgmtd:remove_schema(draft7).

yang_module_name_differs_from_prefix() ->
    ok = mgmtd:load_yang_module("test/yang/example-server.yang"),
    Info = info(ex),
    ?assertEqual("example-server", maps:get(module, Info)),
    ?assertEqual("urn:example:server", maps:get(namespace, Info)),
    ?assertEqual(yang, maps:get(source, Info)),
    ?assertEqual(ex, maps:get(prefix, Info)),
    ok = mgmtd:remove_schema(ex).

restconf_module_override() ->
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                    #{namespace => example,
                                      restconf_module => "example-server-json"}),
    Info = info(example),
    ?assertEqual("example-server-json", maps:get(module, Info)),
    ?assertEqual("urn:mgmtd:example", maps:get(namespace, Info)),
    ok = mgmtd:remove_schema(example).

modules_state_lists_all_sources() ->
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                    #{namespace => example}),
    ok = mgmtd:load_json_schema("test/json_schema_draft07.json",
                                #{namespace => draft7}),
    ok = mgmtd:load_yang_module("test/yang/example-server.yang"),
    Names = [maps:get(name, M) || M <- mgmtd_restconf_yanglib:modules()],
    ?assert(lists:member("default", Names)),
    ?assert(lists:member("example", Names)),
    ?assert(lists:member("draft7", Names)),
    ?assert(lists:member("example-server", Names)),
    ?assert(lists:member("ietf-yang-library", Names)),
    #{<<"ietf-yang-library:modules-state">> := State} =
        mgmtd_restconf_yanglib:modules_state(),
    JsonNames = [maps:get(<<"name">>, M) || M <- maps:get(<<"module">>, State)],
    ?assert(lists:member(<<"example-server">>, JsonNames)),
    ?assert(lists:member(<<"draft7">>, JsonNames)),
    ?assertEqual(list_to_binary(mgmtd_restconf_yanglib:module_set_id()),
                 maps:get(<<"module-set-id">>, State)).

info(Prefix) ->
    [I] = [X || #{prefix := P} = X <- mgmtd_schema:loaded_schema_infos(),
                P =:= Prefix],
    I.
