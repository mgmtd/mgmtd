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