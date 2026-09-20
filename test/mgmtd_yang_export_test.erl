-module(mgmtd_yang_export_test).

-include_lib("eunit/include/eunit.hrl").

export_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun function_schema_is_valid_yang/0,
      fun round_trip_function_schema/0,
      fun original_yang_source_is_kept/0,
      fun stdlib_inet_types/0,
      fun stdlib_mgmtd_extensions/0,
      fun data_callback_is_exported/0,
      fun schema_uri_omits_builtins/0,
      fun unknown_module/0]}.

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

function_schema_is_valid_yang() ->
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                    #{namespace => example}),
    {ok, Yang} = mgmtd:export_yang("example"),
    ?assert(binary:match(Yang, <<"module example">>) =/= nomatch),
    ?assert(binary:match(Yang, <<"namespace \"urn:mgmtd:example\"">>) =/= nomatch),
    ?assert(binary:match(Yang, <<"import ietf-inet-types">>) =/= nomatch),
    ?assert(binary:match(Yang, <<"container server">>) =/= nomatch),
    ?assert(binary:match(Yang, <<"list servers">>) =/= nomatch),
    ?assert(binary:match(Yang, <<"key \"name\"">>) =/= nomatch),
    ?assert(binary:match(Yang, <<"enum \"1GbE\"">>) =/= nomatch),
    {ok, [{module, _, <<"example">>, _}]} = mgmtd_yang_parse:string(Yang),
    ok = mgmtd:remove_schema(example).

round_trip_function_schema() ->
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                    #{namespace => example}),
    {ok, Yang} = mgmtd:export_yang("example"),
    ok = mgmtd:remove_schema(example),
    Tmp = "test/.mgmtd_export_tmp.yang",
    ok = file:write_file(Tmp, Yang),
    try
        ?assertEqual(ok, mgmtd:load_yang_module(Tmp)),
        #{node_type := leaf, type := 'inet:port-number'} =
            mgmtd_schema:lookup(["example", "server", "servers", "port"]),
        #{node_type := list, key_names := ["name"]} =
            mgmtd_schema:lookup(["example", "server", "servers"])
    after
        file:delete(Tmp),
        _ = mgmtd:remove_schema(example)
    end.

original_yang_source_is_kept() ->
    File = "test/yang/example-server.yang",
    {ok, Original} = file:read_file(File),
    ok = mgmtd:load_yang_module(File),
    {ok, Body} = mgmtd:export_yang("example-server"),
    ?assertEqual(Original, Body),
    ok = mgmtd:remove_schema(ex).

stdlib_inet_types() ->
    {ok, Body} = mgmtd:export_yang("ietf-inet-types"),
    ?assert(binary:match(Body, <<"module ietf-inet-types">>) =/= nomatch),
    {ok, Same} = mgmtd:export_yang("ietf-inet-types", "2013-07-15"),
    ?assertEqual(Body, Same),
    ?assertEqual({error, not_found},
                 mgmtd:export_yang("ietf-inet-types", "1999-01-01")).

stdlib_mgmtd_extensions() ->
    {ok, Body} = mgmtd:export_yang("mgmtd"),
    ?assert(binary:match(Body, <<"module mgmtd">>) =/= nomatch),
    ?assert(binary:match(Body, <<"extension data-callback">>) =/= nomatch),
    ?assert(binary:match(Body, <<"extension codec">>) =/= nomatch),
    {ok, Same} = mgmtd:export_yang("mgmtd", "2026-09-20"),
    ?assertEqual(Body, Same).

data_callback_is_exported() ->
    ok = mgmtd:load_function_schema(fun mgmtd_test_provider:schema/0,
                                    #{namespace => oper}),
    {ok, Yang} = mgmtd:export_yang("oper"),
    ?assert(binary:match(Yang, <<"import mgmtd">>) =/= nomatch),
    ?assert(binary:match(Yang, <<"mgmtd:data-callback \"mgmtd_test_provider\"">>)
            =/= nomatch),
    ok = mgmtd:remove_schema(oper),
    Tmp = "test/.mgmtd_export_oper.yang",
    ok = file:write_file(Tmp, Yang),
    try
        ?assertEqual(ok, mgmtd:load_yang_module(Tmp)),
        ?assertEqual(mgmtd_test_provider,
                     mgmtd_schema:data_callback(["oper", "status"])),
        ?assertEqual(mgmtd_test_provider,
                     mgmtd_schema:data_callback(["oper", "status", "uptime"]))
    after
        file:delete(Tmp),
        _ = mgmtd:remove_schema(oper)
    end.

schema_uri_omits_builtins() ->
    Builtin = #{name => "ietf-yang-library",
                revision => "2016-06-21",
                source => builtin},
    ?assertEqual(undefined, mgmtd_yang_export:schema_uri(Builtin)),
    Fun = #{name => "example", revision => "", source => function},
    ?assertEqual("/restconf/yang/example", mgmtd_yang_export:schema_uri(Fun)),
    Std = #{name => "ietf-inet-types",
            revision => "2013-07-15",
            source => stdlib},
    ?assertEqual("/restconf/yang/ietf-inet-types/2013-07-15",
                 mgmtd_yang_export:schema_uri(Std)).

unknown_module() ->
    ?assertEqual({error, not_found}, mgmtd:export_yang("no-such-module")).
