%%%-------------------------------------------------------------------
%%% @doc RESTCONF api-path translation tests.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_path_test).

-include_lib("eunit/include/eunit.hrl").

parse_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun datastore/0,
      fun default_prefix_container/0,
      fun default_list_instance/0,
      fun named_prefix_strips_cli_container/0,
      fun yang_module_name_not_prefix/0,
      fun json_schema_module/0,
      fun compound_config_keys_stay_strings/0,
      fun operational_keys_are_internal/0,
      fun unknown_module/0,
      fun unknown_node/0,
      fun unqualified_top_level/0]}.

setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                    #{namespace => example}),
    ok = mgmtd:load_function_schema(fun mgmtd_test_provider:schema/0),
    ok = mgmtd:load_yang_module("test/yang/example-server.yang"),
    File = json_file(),
    ok = file:write_file(File, json_schema()),
    ok = mgmtd:load_json_schema(File, #{namespace => js, config => true}),
    ok.

teardown(_) ->
    file:delete(json_file()),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

datastore() ->
    ?assertEqual({ok, datastore},
                 mgmtd_restconf_path:parse(<<"/restconf/data">>)),
    ?assertEqual({ok, datastore},
                 mgmtd_restconf_path:parse(<<"/restconf/data/">>)).

default_prefix_container() ->
    {ok, #{module := "default", prefix := default, item_path := Path,
           schema := #{node_type := container, name := "server"}}} =
        mgmtd_restconf_path:parse(<<"/restconf/data/default:server">>),
    ?assertEqual(["server"], Path).

default_list_instance() ->
    {ok, #{item_path := Path, schema := #{node_type := leaf, name := "port"}}} =
        mgmtd_restconf_path:parse(
          <<"/restconf/data/default:server/servers=web/port">>),
    ?assertEqual(["server", "servers", {"web"}, "port"], Path).

named_prefix_strips_cli_container() ->
    {ok, #{module := "example", prefix := example, item_path := Path}} =
        mgmtd_restconf_path:parse(
          <<"/restconf/data/example:server/servers=ex1">>),
    ?assertEqual(["example", "server", "servers", {"ex1"}], Path).

yang_module_name_not_prefix() ->
    {ok, #{module := "example-server", prefix := ex, item_path := Path}} =
        mgmtd_restconf_path:parse(
          <<"/restconf/data/example-server:server/servers=yang1">>),
    ?assertEqual(["ex", "server", "servers", {"yang1"}], Path).

json_schema_module() ->
    {ok, #{module := "js", prefix := js, item_path := Path}} =
        mgmtd_restconf_path:parse(<<"/restconf/data/js:app/title">>),
    ?assertEqual(["js", "app", "title"], Path).

compound_config_keys_stay_strings() ->
    {ok, #{item_path := Path}} =
        mgmtd_restconf_path:parse(
          <<"/restconf/data/default:client/clients=127.0.0.1,82/name">>),
    ?assertEqual(["client", "clients", {"127.0.0.1", "82"}, "name"], Path).

operational_keys_are_internal() ->
    {ok, #{item_path := Path}} =
        mgmtd_restconf_path:parse(
          <<"/restconf/data/default:status/peers=127.0.0.1,8080/state">>),
    ?assertEqual(["status", "peers", {{127,0,0,1}, 8080}, "state"], Path).

unknown_module() ->
    {error, #{http := 404}} =
        mgmtd_restconf_path:parse(<<"/restconf/data/no-such:foo">>).

unknown_node() ->
    {error, #{http := 404}} =
        mgmtd_restconf_path:parse(<<"/restconf/data/default:nope">>).

unqualified_top_level() ->
    {error, #{http := 400}} =
        mgmtd_restconf_path:parse(<<"/restconf/data/server">>).

json_file() ->
    "test/json_schema_restconf_path.json".

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
