%%%-------------------------------------------------------------------
%%% @doc RESTCONF GET of data resources (function, JSON Schema, YANG).
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_data_test).

-include_lib("eunit/include/eunit.hrl").

-define(DB, "test_db_restconf").

get_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun default_leaf/0,
      fun with_defaults_trim/0,
      fun with_defaults_explicit/0,
      fun default_list_instance/0,
      fun named_prefix_leaf/0,
      fun json_schema_leaf_and_list/0,
      fun yang_module_leaf/0,
      fun compound_key/0,
      fun operational_leaf/0,
      fun content_config_hides_operational/0,
      fun content_nonconfig_hides_config/0,
      fun missing_instance/0,
      fun defaulted_leaf/0,
      fun http_get_default_leaf/0,
      fun http_get_json_schema/0,
      fun http_get_yang/0]}.

setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB, [{backend, mnesia}]),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                    #{namespace => example}),
    ok = mgmtd:load_function_schema(fun mgmtd_test_provider:schema/0),
    ok = mgmtd:load_yang_module("test/yang/example-server.yang"),
    File = json_file(),
    ok = file:write_file(File, json_schema()),
    ok = mgmtd:load_json_schema(File, #{namespace => js, config => true}),
    ok = mgmtd_cfg_db:init(?DB, [{backend, mnesia}]),
    ok = commit_sets(
           [["server", "servers", {"web"}, "port", "81"],
            ["client", "clients", {"127.0.0.1", "82"}, "name", "c1"],
            ["example", "server", "servers", {"ex1"}, "port", "82"],
            ["js", "app", "title", "demo"],
            ["js", "app", "enabled", "true"],
            ["js", "app", "listeners", {"http"}, "port", "8080"],
            ["ex", "server", "servers", {"yang1"}, "port", "83"]]),
    Prev = application:get_env(mgmtd, restconf_port),
    ok = application:set_env(mgmtd, restconf_port, 0),
    ok = mgmtd_restconf:start(),
    {ok, _} = application:ensure_all_started(inets),
    Prev.

teardown(Prev) ->
    ok = mgmtd_restconf:stop(),
    case Prev of
        undefined -> application:unset_env(mgmtd, restconf_port);
        {ok, Port} -> application:set_env(mgmtd, restconf_port, Port)
    end,
    file:delete(json_file()),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB, [{backend, mnesia}]),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

commit_sets(Paths) ->
    Txn1 = lists:foldl(
             fun(P, Txn) ->
                     {ok, SP} = mgmtd_schema:lookup_path(P),
                     {ok, T} = mgmtd:txn_set(Txn, SP),
                     T
             end, mgmtd:txn_new(), Paths),
    {ok, _} = mgmtd:txn_commit(Txn1),
    ok.

default_leaf() ->
    {ok, Map} = mgmtd_restconf_data:resource(
                  <<"/restconf/data/default:server/servers=web/port">>, all),
    ?assertEqual(#{<<"default:port">> => 81}, Map).

default_list_instance() ->
    {ok, #{<<"default:servers">> := [Item]}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/default:server/servers=web">>, all),
    ?assertEqual(<<"web">>, maps:get(<<"name">>, Item)),
    ?assertEqual(81, maps:get(<<"port">>, Item)).

named_prefix_leaf() ->
    {ok, Map} = mgmtd_restconf_data:resource(
                  <<"/restconf/data/example:server/servers=ex1/port">>, all),
    ?assertEqual(#{<<"example:port">> => 82}, Map).

json_schema_leaf_and_list() ->
    {ok, Title} = mgmtd_restconf_data:resource(
                    <<"/restconf/data/js:app/title">>, all),
    ?assertEqual(#{<<"js:title">> => <<"demo">>}, Title),
    {ok, #{<<"js:app">> := App}} =
        mgmtd_restconf_data:resource(<<"/restconf/data/js:app">>, all),
    ?assertEqual(<<"demo">>, maps:get(<<"title">>, App)),
    ?assertEqual(true, maps:get(<<"enabled">>, App)),
    [Listener] = maps:get(<<"listeners">>, App),
    ?assertEqual(<<"http">>, maps:get(<<"name">>, Listener)),
    ?assertEqual(8080, maps:get(<<"port">>, Listener)).

yang_module_leaf() ->
    {ok, Map} = mgmtd_restconf_data:resource(
                  <<"/restconf/data/example-server:server/servers=yang1/port">>,
                  all),
    ?assertEqual(#{<<"example-server:port">> => 83}, Map).

compound_key() ->
    {ok, Map} = mgmtd_restconf_data:resource(
                  <<"/restconf/data/default:client/clients=127.0.0.1,82/name">>,
                  all),
    ?assertEqual(#{<<"default:name">> => <<"c1">>}, Map).

operational_leaf() ->
    {ok, Map} = mgmtd_restconf_data:resource(
                  <<"/restconf/data/default:status/uptime">>, all),
    ?assertEqual(#{<<"default:uptime">> => <<"1d4h">>}, Map),
    {ok, Mtu} = mgmtd_restconf_data:resource(
                  <<"/restconf/data/default:status/interfaces=eth0/mtu">>, all),
    ?assertEqual(#{<<"default:mtu">> => 1500}, Mtu),
    {ok, Tags} = mgmtd_restconf_data:resource(
                   <<"/restconf/data/default:status/tags">>, all),
    ?assertEqual(#{<<"default:tags">> => [<<"core">>, <<"edge">>]}, Tags).

content_config_hides_operational() ->
    {error, #{http := 404}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/default:status/uptime">>, config),
    {ok, Map} = mgmtd_restconf_data:resource(
                  <<"/restconf/data/default:server/servers=web/port">>, config),
    ?assertEqual(#{<<"default:port">> => 81}, Map).

content_nonconfig_hides_config() ->
    {error, #{http := 404}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/default:server/servers=web/port">>, nonconfig),
    {ok, #{<<"ietf-yang-library:modules-state">> := _}} =
        mgmtd_restconf_data:resource(<<"/restconf/data">>, nonconfig).

missing_instance() ->
    {error, #{http := 404}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/default:server/servers=nope">>, all).

defaulted_leaf() ->
    {ok, Map} = mgmtd_restconf_data:resource(
                  <<"/restconf/data/default:interface/speed">>, all),
    ?assertEqual(#{<<"default:speed">> => <<"1GbE">>}, Map).

with_defaults_trim() ->
    {ok, #{<<"default:interface">> := Iface}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/default:interface">>,
          #{content => all, defaults => trim}),
    ?assertEqual(false, maps:is_key(<<"speed">>, Iface)).

with_defaults_explicit() ->
    {ok, #{<<"default:interface">> := Iface}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/default:interface">>,
          #{content => all, defaults => explicit}),
    ?assertEqual(false, maps:is_key(<<"speed">>, Iface)),
    {ok, #{<<"default:speed">> := <<"1GbE">>}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/default:interface/speed">>,
          #{content => all, defaults => report_all}).

http_get_default_leaf() ->
    {Code, _, Body} = http_get("/restconf/data/default:server/servers=web/port"),
    ?assertEqual(200, Code),
    ?assertEqual(#{<<"default:port">> => 81}, json:decode(Body)).

http_get_json_schema() ->
    {Code, _, Body} = http_get("/restconf/data/js:app/title"),
    ?assertEqual(200, Code),
    ?assertEqual(#{<<"js:title">> => <<"demo">>}, json:decode(Body)).

http_get_yang() ->
    {Code, _, Body} =
        http_get("/restconf/data/example-server:server/servers=yang1/port"),
    ?assertEqual(200, Code),
    ?assertEqual(#{<<"example-server:port">> => 83}, json:decode(Body)).

http_get(Path) ->
    Url = lists:flatten(
            io_lib:format("http://127.0.0.1:~p~s",
                          [mgmtd_restconf:port(), Path])),
    {ok, {{_, Code, _}, Headers, Body}} =
        httpc:request(get, {Url, []}, [{timeout, 2000}],
                      [{body_format, binary}]),
    {Code, Headers, Body}.

json_file() ->
    "test/json_schema_restconf_data.json".

json_schema() ->
    <<"{
        \"$schema\": \"http://json-schema.org/draft-07/schema#\",
        \"type\": \"object\",
        \"properties\": {
            \"app\": {
                \"type\": \"object\",
                \"properties\": {
                    \"title\": {\"type\": \"string\"},
                    \"enabled\": {\"type\": \"boolean\"},
                    \"tags\": {
                        \"type\": \"array\",
                        \"items\": {\"type\": \"string\"}
                    },
                    \"listeners\": {
                        \"type\": \"array\",
                        \"keys\": [\"name\"],
                        \"items\": {
                            \"type\": \"object\",
                            \"properties\": {
                                \"name\": {\"type\": \"string\"},
                                \"port\": {\"type\": \"integer\"}
                            }
                        }
                    }
                }
            }
        }
    }">>.
