%%%-------------------------------------------------------------------
%%% @doc RESTCONF PUT/POST/PATCH/DELETE against running.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_write_test).

-include_lib("eunit/include/eunit.hrl").

-define(DB, "test_db_restconf_write").

write_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun post_creates_list_item/0,
      fun post_duplicate_conflicts/0,
      fun put_replaces_leaf/0,
      fun put_creates_list_instance/0,
      fun patch_merges_leaf/0,
      fun delete_list_item/0,
      fun operational_write_rejected/0,
      fun invalid_type/0,
      fun json_schema_post/0,
      fun named_prefix_put/0,
      fun yang_put/0,
      fun http_post_location/0]}.

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

post_creates_list_item() ->
    Body = #{<<"default:servers">> =>
                 [#{<<"name">> => <<"web">>, <<"port">> => 81}]},
    {ok, Loc} = mgmtd_restconf_data:post(
                  <<"/restconf/data/default:server/servers">>, Body),
    ?assertEqual(<<"/restconf/data/default:server/servers=web">>, Loc),
    {ok, #{<<"default:port">> := 81}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/default:server/servers=web/port">>, all).

post_duplicate_conflicts() ->
    Body = #{<<"default:servers">> =>
                 [#{<<"name">> => <<"dup">>, <<"port">> => 1}]},
    {ok, _} = mgmtd_restconf_data:post(
                <<"/restconf/data/default:server/servers">>, Body),
    {error, #{http := 409, tag := <<"data-exists">>}} =
        mgmtd_restconf_data:post(
          <<"/restconf/data/default:server/servers">>, Body).

put_replaces_leaf() ->
    Body = #{<<"default:servers">> =>
                 [#{<<"name">> => <<"p1">>, <<"port">> => 10}]},
    {ok, _} = mgmtd_restconf_data:post(
                <<"/restconf/data/default:server/servers">>, Body),
    {ok, replaced} = mgmtd_restconf_data:put(
                       <<"/restconf/data/default:server/servers=p1/port">>,
                       #{<<"default:port">> => 11}),
    {ok, #{<<"default:port">> := 11}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/default:server/servers=p1/port">>, all).

put_creates_list_instance() ->
    {ok, created} = mgmtd_restconf_data:put(
                      <<"/restconf/data/default:server/servers=p2">>,
                      #{<<"default:servers">> =>
                            [#{<<"name">> => <<"p2">>, <<"port">> => 12}]}),
    {ok, #{<<"default:port">> := 12}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/default:server/servers=p2/port">>, all).

patch_merges_leaf() ->
    {ok, _} = mgmtd_restconf_data:put(
                <<"/restconf/data/default:server/servers=p3">>,
                #{<<"default:servers">> =>
                      [#{<<"name">> => <<"p3">>, <<"port">> => 13}]}),
    ok = mgmtd_restconf_data:patch(
           <<"/restconf/data/default:server/servers=p3">>,
           #{<<"default:servers">> => [#{<<"port">> => 14}]}),
    {ok, #{<<"default:port">> := 14}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/default:server/servers=p3/port">>, all),
    {ok, #{<<"default:name">> := <<"p3">>}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/default:server/servers=p3/name">>, all).

delete_list_item() ->
    {ok, _} = mgmtd_restconf_data:put(
                <<"/restconf/data/default:server/servers=gone">>,
                #{<<"default:servers">> =>
                      [#{<<"name">> => <<"gone">>, <<"port">> => 1}]}),
    ok = mgmtd_restconf_data:delete(
           <<"/restconf/data/default:server/servers=gone">>),
    {error, #{http := 404}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/default:server/servers=gone">>, all).

operational_write_rejected() ->
    {error, #{http := 405}} =
        mgmtd_restconf_data:put(
          <<"/restconf/data/default:status/uptime">>,
          #{<<"default:uptime">> => <<"nope">>}).

invalid_type() ->
    {error, #{http := 400, tag := <<"invalid-value">>}} =
        mgmtd_restconf_data:put(
          <<"/restconf/data/default:server/servers=bad">>,
          #{<<"default:servers">> =>
                [#{<<"name">> => <<"bad">>, <<"port">> => <<"x">>}]}).

json_schema_post() ->
    {ok, Loc} = mgmtd_restconf_data:post(
                  <<"/restconf/data/js:app/listeners">>,
                  #{<<"js:listeners">> =>
                        [#{<<"name">> => <<"http">>, <<"port">> => 8080}]}),
    ?assertEqual(<<"/restconf/data/js:app/listeners=http">>, Loc),
    {ok, #{<<"js:port">> := 8080}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/js:app/listeners=http/port">>, all).

named_prefix_put() ->
    {ok, created} = mgmtd_restconf_data:put(
                      <<"/restconf/data/example:server/servers=ex1">>,
                      #{<<"example:servers">> =>
                            [#{<<"name">> => <<"ex1">>, <<"port">> => 82}]}),
    {ok, #{<<"example:port">> := 82}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/example:server/servers=ex1/port">>, all).

yang_put() ->
    {ok, created} = mgmtd_restconf_data:put(
                      <<"/restconf/data/example-server:server/servers=yang1">>,
                      #{<<"example-server:servers">> =>
                            [#{<<"name">> => <<"yang1">>, <<"port">> => 83}]}),
    {ok, #{<<"example-server:port">> := 83}} =
        mgmtd_restconf_data:resource(
          <<"/restconf/data/example-server:server/servers=yang1/port">>, all).

http_post_location() ->
    Body = jsx_or_json(#{<<"default:servers">> =>
                             [#{<<"name">> => <<"http1">>, <<"port">> => 7}]}),
    Url = lists:flatten(
            io_lib:format(
              "http://127.0.0.1:~p/restconf/data/default:server/servers",
              [mgmtd_restconf:port()])),
    {ok, {{_, Code, _}, Headers, _}} =
        httpc:request(post,
                      {Url,
                       [{"Content-Type", "application/yang-data+json"}],
                       "application/yang-data+json", Body},
                      [{timeout, 2000}], [{body_format, binary}]),
    ?assertEqual(201, Code),
    Loc = header("location", Headers),
    ?assertEqual("/restconf/data/default:server/servers=http1", Loc),
    GetUrl = lists:flatten(
               io_lib:format("http://127.0.0.1:~p~s/port",
                             [mgmtd_restconf:port(), Loc])),
    {ok, {{_, 200, _}, _, GetBody}} =
        httpc:request(get, {GetUrl, []}, [{timeout, 2000}],
                      [{body_format, binary}]),
    ?assertEqual(#{<<"default:port">> => 7}, json:decode(GetBody)).

header(Name, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> V;
        false ->
            lists:keyfind(string:lowercase(Name), 1, Headers)
    end.

jsx_or_json(Map) ->
    iolist_to_binary(json:encode(Map)).

json_file() ->
    "test/json_schema_restconf_write.json".

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
