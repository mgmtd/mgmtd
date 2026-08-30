-module(mgmtd_schema_tests).

-include_lib("eunit/include/eunit.hrl").

parse_ae_config_schema_test() ->
    %% io:format(user, "CWD ~p~n", [file:get_cwd()]),
    mgmtd_sup:start_link(),
    ok = mgmtd:load_json_schema("test/aeternity_config_schema.json"),
    [_] = mgmtd:registered_schemas(),
    #{type := Type} = mgmtd_schema:lookup(["logging", "level"]),
    ?assertEqual({enum, ["debug", "info", "warning", "error", "none"]}, Type),
    ok = mgmtd:remove_schema(),
    [] = mgmtd:registered_schemas().

parse_draft07_schema_test() ->
    mgmtd_sup:start_link(),
    ok = mgmtd:load_json_schema("test/json_schema_draft07.json"),
    #{type := ModeType} = mgmtd_schema:lookup(["mode"]),
    ?assertEqual({enum, ["active"]}, ModeType),
    #{type := CountType} = mgmtd_schema:lookup(["count"]),
    ?assertEqual({int32, [{min, 1}, {max, 10}]}, CountType),
    #{type := LevelType} = mgmtd_schema:lookup(["level"]),
    ?assertEqual({int32, [{min, 1}, {max, 4}]}, LevelType),
    #{node_type := leaf_list, min_elements := 1, max_elements := 4} =
        mgmtd_schema:lookup(["tags"]),
    ok = mgmtd:remove_schema().

reject_draft04_schema_test() ->
    mgmtd_sup:start_link(),
    File = "test/json_schema_draft04_rejected.json",
    ok = file:write_file(File, <<"{
        \"$schema\": \"http://json-schema.org/draft-04/schema#\",
        \"type\": \"object\",
        \"properties\": {}
    }">>),
    try
        ?assertEqual({error, {unsupported_json_schema,
                              <<"http://json-schema.org/draft-04/schema#">>}},
                     mgmtd:load_json_schema(File))
    after
        file:delete(File)
    end.

reject_missing_schema_uri_test() ->
    mgmtd_sup:start_link(),
    File = "test/json_schema_missing_dollar_schema.json",
    ok = file:write_file(File, <<"{\"type\": \"object\", \"properties\": {}}">>),
    try
        ?assertEqual({error, {unsupported_json_schema, missing_dollar_schema}},
                     mgmtd:load_json_schema(File))
    after
        file:delete(File)
    end.

multiple_schema_load_test() ->
    %% io:format(user, "CWD ~p~n", [file:get_cwd()]),
    mgmtd_sup:start_link(),
    ok = mgmtd:load_json_schema("test/aeternity_config_schema.json"),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,  #{namespace => function_ns}),
    [_,_] = mgmtd:registered_schemas(),
    ok = mgmtd:remove_schema(),
    [function_ns] = mgmtd:registered_schemas(),
    ok = mgmtd:remove_schema(function_ns),
    [] = mgmtd:registered_schemas().

named_prefix_root_children_test() ->
    mgmtd_sup:start_link(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                    #{namespace => example}),
    Root = [maps:get(name, C) || C <- mgmtd:schema_children([], set)],
    ?assert(lists:member("server", Root)),
    ?assert(lists:member("example", Root)),
    ?assertEqual(1, length([N || N <- Root, N =:= "server"])),
    Prefixed = [maps:get(name, C) || C <- mgmtd:schema_children(["example"], set)],
    ?assert(lists:member("server", Prefixed)),
    ?assertNot(lists:member("example", Prefixed)),
    #{ns := example, path := ["example"], has_list := true,
      node_type := container} =
        mgmtd_schema:lookup(["example"]),
    #{ns := example, path := ["example", "server"], has_list := true} =
        mgmtd_schema:lookup(["example", "server"]),
    #{ns := default, path := ["server"]} =
        mgmtd_schema:lookup(["server"]),
    Delete = [maps:get(name, C) || C <- mgmtd:schema_children([], delete)],
    ?assert(lists:member("example", Delete)),
    ok = mgmtd:remove_schema(example),
    ok = mgmtd:remove_schema().

prefix_conflicts_with_default_root_test() ->
    mgmtd_sup:start_link(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ?assertEqual({error, {prefix_conflicts_with_node, "server"}},
                 mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                            #{namespace => server})),
    ok = mgmtd:remove_schema().

default_conflicts_with_named_prefix_test() ->
    mgmtd_sup:start_link(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                    #{namespace => server}),
    ?assertEqual({error, {prefix_conflicts_with_node, "server"}},
                 mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0)),
    ok = mgmtd:remove_schema(server).

missing_prefix_for_uri_namespace_test() ->
    mgmtd_sup:start_link(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ?assertEqual({error, missing_prefix},
                 mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                            #{namespace => "urn:example:ns"})).

invalid_prefix_test() ->
    mgmtd_sup:start_link(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ?assertEqual({error, {invalid_prefix, 'foo:bar'}},
                 mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                            #{namespace => 'foo:bar'})).

same_prefix_different_uri_test() ->
    mgmtd_sup:start_link(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                    #{prefix => example,
                                      namespace => "urn:example:one"}),
    ?assertEqual({error, {prefix_namespace_mismatch, example, "urn:example:one"}},
                 mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                            #{prefix => example,
                                              namespace => "urn:example:two"})),
    ok = mgmtd:remove_schema(example).

json_leaf_list_does_not_set_has_list_on_prefix_test() ->
    mgmtd_sup:start_link(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd:load_json_schema("test/json_schema_draft07.json",
                                #{namespace => draft07}),
    #{has_list := false, node_type := container} =
        mgmtd_schema:lookup(["draft07"]),
    ?assertNot(lists:member("draft07",
                            [maps:get(name, C)
                             || C <- mgmtd:schema_children([], delete)])),
    ?assert(lists:member("draft07",
                         [maps:get(name, C)
                          || C <- mgmtd:schema_children([], set)])),
    #{node_type := leaf_list} = mgmtd_schema:lookup(["draft07", "tags"]),
    ok = mgmtd:remove_schema(draft07).

json_list_sets_has_list_on_ancestors_test() ->
    mgmtd_sup:start_link(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    File = "test/json_schema_list_has_list.json",
    ok = file:write_file(File, <<"{
        \"$schema\": \"http://json-schema.org/draft-07/schema#\",
        \"type\": \"object\",
        \"properties\": {
            \"pool\": {
                \"type\": \"object\",
                \"properties\": {
                    \"servers\": {
                        \"type\": \"array\",
                        \"keys\": [\"name\"],
                        \"items\": {
                            \"type\": \"object\",
                            \"properties\": {
                                \"name\": {\"type\": \"string\"}
                            }
                        }
                    }
                }
            }
        }
    }">>),
    try
        ok = mgmtd:load_json_schema(File, #{namespace => jsontest}),
        #{has_list := true, node_type := container} =
            mgmtd_schema:lookup(["jsontest"]),
        #{has_list := true} = mgmtd_schema:lookup(["jsontest", "pool"]),
        #{has_list := true, node_type := list} =
            mgmtd_schema:lookup(["jsontest", "pool", "servers"]),
        ?assert(lists:member("jsontest",
                             [maps:get(name, C)
                              || C <- mgmtd:schema_children([], delete)]))
    after
        file:delete(File),
        mgmtd:remove_schema(jsontest)
    end.