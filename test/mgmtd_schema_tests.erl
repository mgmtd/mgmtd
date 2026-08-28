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