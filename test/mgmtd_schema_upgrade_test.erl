%%%-------------------------------------------------------------------
%%% @doc Automatic schema upgrade of existing configuration rows.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_schema_upgrade_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/mgmtd.hrl").
-include("../src/mgmtd_schema.hrl").

-define(MNESIA_DIR, "test_db_upgrade_mnesia").
-define(JSON_DIR, "test_db_upgrade_json").

%%--------------------------------------------------------------------
%% Suite
%%--------------------------------------------------------------------
schema_upgrade_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [fun delete_removed_leaf/0,
      fun reorder_siblings_keeps_values/0,
      fun port_to_string/0,
      fun string_to_integer/0,
      fun out_of_range_uses_default/0,
      fun out_of_range_without_default_fails/0,
      fun changed_default_keeps_stored_value/0,
      fun new_defaulted_leaf_not_inserted/0,
      fun list_key_type_coercion/0,
      fun list_key_added_deletes_instance/0,
      fun compound_key_removed/0,
      fun compound_key_reordered/0,
      fun json_int_canonicalized_as_string/0,
      fun json_unknown_member_dropped/0]}.

setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?MNESIA_DIR, [{backend, mnesia}]),
    ok = mgmtd_cfg_db:remove_db(?JSON_DIR, [{backend, json}]),
    ok.

teardown(_) ->
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?MNESIA_DIR, [{backend, mnesia}]),
    ok = mgmtd_cfg_db:remove_db(?JSON_DIR, [{backend, json}]),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------
delete_removed_leaf() ->
    load(fun v1/0),
    ok = init_mnesia(),
    {ok, _} = commit_set(["box", "extra", "gone"]),
    {ok, _} = commit_set(["box", "name", "r1"]),
    reload(fun v1_no_extra/0),
    ok = reopen_mnesia(),
    ?assertEqual([], mgmtd_cfg_db:lookup(["box", "extra"])),
    ?assertEqual({ok, "r1"}, mgmtd:lookup(["box", "name"])).

reorder_siblings_keeps_values() ->
    load(fun v1/0),
    ok = init_mnesia(),
    {ok, _} = commit_set(["box", "name", "r1"]),
    {ok, _} = commit_set(["box", "port", "81"]),
    reload(fun v1_reordered/0),
    ok = reopen_mnesia(),
    ?assertEqual({ok, "r1"}, mgmtd:lookup(["box", "name"])),
    ?assertEqual({ok, 81}, mgmtd:lookup(["box", "port"])).

port_to_string() ->
    load(fun v1/0),
    ok = init_mnesia(),
    {ok, _} = commit_set(["box", "port", "81"]),
    reload(fun v1_port_string/0),
    ok = reopen_mnesia(),
    ?assertEqual({ok, "81"}, mgmtd:lookup(["box", "port"])).

string_to_integer() ->
    load(fun v1/0),
    ok = init_mnesia(),
    {ok, _} = commit_set(["box", "tag", "80"]),
    reload(fun v1_tag_int/0),
    ok = reopen_mnesia(),
    ?assertEqual({ok, 80}, mgmtd:lookup(["box", "tag"])).

out_of_range_uses_default() ->
    load(fun v1/0),
    ok = init_mnesia(),
    {ok, _} = commit_set(["box", "count", "300"]),
    reload(fun v1_count_uint8_default/0),
    ok = reopen_mnesia(),
    ?assertEqual({ok, 1}, mgmtd:lookup(["box", "count"])).

out_of_range_without_default_fails() ->
    load(fun v1/0),
    ok = init_mnesia(),
    {ok, _} = commit_set(["box", "count", "300"]),
    reload(fun v1_count_uint8/0),
    ?assertMatch({error, {schema_upgrade, ["box", "count"], _}},
                 reopen_mnesia()),
    reload(fun v1/0),
    ok = reopen_mnesia(),
    ?assertEqual({ok, 300}, mgmtd:lookup(["box", "count"])).

changed_default_keeps_stored_value() ->
    load(fun v1/0),
    ok = init_mnesia(),
    {ok, _} = commit_set(["box", "port", "80"]),
    reload(fun v1_port_new_default/0),
    ok = reopen_mnesia(),
    ?assertEqual({ok, 80}, mgmtd:lookup(["box", "port"])).

new_defaulted_leaf_not_inserted() ->
    load(fun v1/0),
    ok = init_mnesia(),
    {ok, _} = commit_set(["box", "name", "r1"]),
    reload(fun v1_with_color/0),
    ok = reopen_mnesia(),
    ?assertEqual([], mgmtd_cfg_db:lookup(["box", "color"])),
    ?assertEqual({ok, "r1"}, mgmtd:lookup(["box", "name"])).

list_key_type_coercion() ->
    load(fun v1/0),
    ok = init_mnesia(),
    {ok, _} = commit_set(["box", "clients", {"127.0.0.1", "82"}, "nick", "n1"]),
    reload(fun v1_client_port_string/0),
    ok = reopen_mnesia(),
    Item = ["box", "clients", {"127.0.0.1", "82"}],
    ?assertEqual({ok, "82"}, mgmtd:lookup(Item ++ ["port"])),
    ?assertEqual({ok, "n1"}, mgmtd:lookup(Item ++ ["nick"])).

list_key_added_deletes_instance() ->
    load(fun v1/0),
    ok = init_mnesia(),
    {ok, _} = commit_set(["box", "servers", {"web1"}, "port", "81"]),
    reload(fun v1_server_extra_key/0),
    ok = reopen_mnesia(),
    ?assertEqual({ok, []}, mgmtd:lookup(["box", "servers"])),
    ?assertEqual([], mgmtd_cfg_db:lookup(["box", "servers", {"web1"}])).

compound_key_removed() ->
    load(fun v1/0),
    ok = init_mnesia(),
    {ok, _} = commit_set(["box", "clients", {"127.0.0.1", "82"}, "nick", "n1"]),
    reload(fun v1_client_host_only_key/0),
    ok = reopen_mnesia(),
    Item = ["box", "clients", {"127.0.0.1"}],
    ?assertEqual({ok, [{"127.0.0.1"}]}, mgmtd:lookup(["box", "clients"])),
    ?assertEqual({ok, "n1"}, mgmtd:lookup(Item ++ ["nick"])),
    ?assertEqual({ok, 82}, mgmtd:lookup(Item ++ ["port"])).

compound_key_reordered() ->
    load(fun v1/0),
    ok = init_mnesia(),
    {ok, _} = commit_set(["box", "clients", {"127.0.0.1", "82"}, "nick", "n1"]),
    reload(fun v1_client_keys_swapped/0),
    ok = reopen_mnesia(),
    Item = ["box", "clients", {"82", "127.0.0.1"}],
    ?assertEqual({ok, [{"82", "127.0.0.1"}]}, mgmtd:lookup(["box", "clients"])),
    ?assertEqual({ok, "n1"}, mgmtd:lookup(Item ++ ["nick"])),
    ?assertEqual([], mgmtd_cfg_db:lookup(["box", "clients", {"127.0.0.1", "82"}])).

json_int_canonicalized_as_string() ->
    load(fun v1/0),
    ok = init_json(),
    {ok, _} = commit_set(["box", "port", "81"]),
    reload(fun v1_port_string/0),
    ok = reopen_json(),
    ?assertEqual({ok, "81"}, mgmtd:lookup(["box", "port"])).

json_unknown_member_dropped() ->
    load(fun v1/0),
    ok = init_json(),
    {ok, _} = commit_set(["box", "extra", "gone"]),
    {ok, _} = commit_set(["box", "name", "r1"]),
    reload(fun v1_no_extra/0),
    ok = reopen_json(),
    ?assertEqual([], mgmtd_cfg_db:lookup(["box", "extra"])),
    ?assertEqual({ok, "r1"}, mgmtd:lookup(["box", "name"])).

%%--------------------------------------------------------------------
%% Schemas
%%--------------------------------------------------------------------
v1() ->
    [#container{name = "box", config = true, children = fun v1_box/0}].

v1_box() ->
    [#leaf{name = "name", type = string},
     #leaf{name = "port", type = 'inet:port-number', default = 80},
     #leaf{name = "count", type = int32, default = 1},
     #leaf{name = "tag", type = string},
     #leaf{name = "extra", type = string},
     #list{name = "servers", key_names = ["name"],
           children = fun server_schema/0},
     #list{name = "clients", key_names = ["host", "port"],
           children = fun client_schema/0}].

v1_no_extra() ->
    [#container{name = "box", config = true, children = fun v1_box_no_extra/0}].

v1_box_no_extra() ->
    [#leaf{name = "name", type = string},
     #leaf{name = "port", type = 'inet:port-number', default = 80},
     #leaf{name = "count", type = int32, default = 1},
     #leaf{name = "tag", type = string},
     #list{name = "servers", key_names = ["name"],
           children = fun server_schema/0},
     #list{name = "clients", key_names = ["host", "port"],
           children = fun client_schema/0}].

v1_reordered() ->
    [#container{name = "box", config = true, children = fun v1_box_reordered/0}].

v1_box_reordered() ->
    [#leaf{name = "port", type = 'inet:port-number', default = 80},
     #leaf{name = "name", type = string},
     #leaf{name = "count", type = int32, default = 1},
     #leaf{name = "tag", type = string},
     #leaf{name = "extra", type = string},
     #list{name = "servers", key_names = ["name"],
           children = fun server_schema/0},
     #list{name = "clients", key_names = ["host", "port"],
           children = fun client_schema/0}].

v1_port_string() ->
    [#container{name = "box", config = true, children = fun v1_box_port_string/0}].

v1_box_port_string() ->
    [#leaf{name = "name", type = string},
     #leaf{name = "port", type = string},
     #leaf{name = "count", type = int32, default = 1},
     #leaf{name = "tag", type = string},
     #leaf{name = "extra", type = string},
     #list{name = "servers", key_names = ["name"],
           children = fun server_schema/0},
     #list{name = "clients", key_names = ["host", "port"],
           children = fun client_schema/0}].

v1_tag_int() ->
    [#container{name = "box", config = true, children = fun v1_box_tag_int/0}].

v1_box_tag_int() ->
    [#leaf{name = "name", type = string},
     #leaf{name = "port", type = 'inet:port-number', default = 80},
     #leaf{name = "count", type = int32, default = 1},
     #leaf{name = "tag", type = int32},
     #leaf{name = "extra", type = string},
     #list{name = "servers", key_names = ["name"],
           children = fun server_schema/0},
     #list{name = "clients", key_names = ["host", "port"],
           children = fun client_schema/0}].

v1_count_uint8() ->
    [#container{name = "box", config = true, children = fun v1_box_count_uint8/0}].

v1_box_count_uint8() ->
    [#leaf{name = "name", type = string},
     #leaf{name = "port", type = 'inet:port-number', default = 80},
     #leaf{name = "count", type = uint8},
     #leaf{name = "tag", type = string},
     #leaf{name = "extra", type = string},
     #list{name = "servers", key_names = ["name"],
           children = fun server_schema/0},
     #list{name = "clients", key_names = ["host", "port"],
           children = fun client_schema/0}].

v1_count_uint8_default() ->
    [#container{name = "box", config = true,
                children = fun v1_box_count_uint8_default/0}].

v1_box_count_uint8_default() ->
    [#leaf{name = "name", type = string},
     #leaf{name = "port", type = 'inet:port-number', default = 80},
     #leaf{name = "count", type = uint8, default = 1},
     #leaf{name = "tag", type = string},
     #leaf{name = "extra", type = string},
     #list{name = "servers", key_names = ["name"],
           children = fun server_schema/0},
     #list{name = "clients", key_names = ["host", "port"],
           children = fun client_schema/0}].

v1_port_new_default() ->
    [#container{name = "box", config = true,
                children = fun v1_box_port_new_default/0}].

v1_box_port_new_default() ->
    [#leaf{name = "name", type = string},
     #leaf{name = "port", type = 'inet:port-number', default = 8080},
     #leaf{name = "count", type = int32, default = 1},
     #leaf{name = "tag", type = string},
     #leaf{name = "extra", type = string},
     #list{name = "servers", key_names = ["name"],
           children = fun server_schema/0},
     #list{name = "clients", key_names = ["host", "port"],
           children = fun client_schema/0}].

v1_with_color() ->
    [#container{name = "box", config = true, children = fun v1_box_color/0}].

v1_box_color() ->
    [#leaf{name = "name", type = string},
     #leaf{name = "port", type = 'inet:port-number', default = 80},
     #leaf{name = "count", type = int32, default = 1},
     #leaf{name = "tag", type = string},
     #leaf{name = "extra", type = string},
     #leaf{name = "color", type = string, default = "red"},
     #list{name = "servers", key_names = ["name"],
           children = fun server_schema/0},
     #list{name = "clients", key_names = ["host", "port"],
           children = fun client_schema/0}].

v1_client_port_string() ->
    [#container{name = "box", config = true,
                children = fun v1_box_client_port_string/0}].

v1_box_client_port_string() ->
    [#leaf{name = "name", type = string},
     #leaf{name = "port", type = 'inet:port-number', default = 80},
     #leaf{name = "count", type = int32, default = 1},
     #leaf{name = "tag", type = string},
     #leaf{name = "extra", type = string},
     #list{name = "servers", key_names = ["name"],
           children = fun server_schema/0},
     #list{name = "clients", key_names = ["host", "port"],
           children = fun client_schema_port_string/0}].

v1_server_extra_key() ->
    [#container{name = "box", config = true,
                children = fun v1_box_server_extra_key/0}].

v1_box_server_extra_key() ->
    [#leaf{name = "name", type = string},
     #leaf{name = "port", type = 'inet:port-number', default = 80},
     #leaf{name = "count", type = int32, default = 1},
     #leaf{name = "tag", type = string},
     #leaf{name = "extra", type = string},
     #list{name = "servers", key_names = ["name", "id"],
           children = fun server_schema_extra_key/0},
     #list{name = "clients", key_names = ["host", "port"],
           children = fun client_schema/0}].

v1_client_host_only_key() ->
    [#container{name = "box", config = true,
                children = fun v1_box_client_host_only/0}].

v1_box_client_host_only() ->
    [#leaf{name = "name", type = string},
     #leaf{name = "port", type = 'inet:port-number', default = 80},
     #leaf{name = "count", type = int32, default = 1},
     #leaf{name = "tag", type = string},
     #leaf{name = "extra", type = string},
     #list{name = "servers", key_names = ["name"],
           children = fun server_schema/0},
     #list{name = "clients", key_names = ["host"],
           children = fun client_schema/0}].

v1_client_keys_swapped() ->
    [#container{name = "box", config = true,
                children = fun v1_box_client_keys_swapped/0}].

v1_box_client_keys_swapped() ->
    [#leaf{name = "name", type = string},
     #leaf{name = "port", type = 'inet:port-number', default = 80},
     #leaf{name = "count", type = int32, default = 1},
     #leaf{name = "tag", type = string},
     #leaf{name = "extra", type = string},
     #list{name = "servers", key_names = ["name"],
           children = fun server_schema/0},
     #list{name = "clients", key_names = ["port", "host"],
           children = fun client_schema/0}].

server_schema() ->
    [#leaf{name = "name", type = string},
     #leaf{name = "port", type = 'inet:port-number', default = 80}].

server_schema_extra_key() ->
    [#leaf{name = "name", type = string},
     #leaf{name = "id", type = string, default = "0"},
     #leaf{name = "port", type = 'inet:port-number', default = 80}].

client_schema() ->
    [#leaf{name = "host", type = 'inet:ip-address'},
     #leaf{name = "port", type = 'inet:port-number'},
     #leaf{name = "nick", type = string}].

client_schema_port_string() ->
    [#leaf{name = "host", type = 'inet:ip-address'},
     #leaf{name = "port", type = string},
     #leaf{name = "nick", type = string}].

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------
load(Fun) ->
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd:load_function_schema(Fun).

reload(Fun) ->
    load(Fun).

init_mnesia() ->
    mgmtd_cfg_db:init(?MNESIA_DIR, [{backend, mnesia}]).

reopen_mnesia() ->
    mgmtd_cfg_db:init(?MNESIA_DIR, [{backend, mnesia}]).

init_json() ->
    mgmtd_cfg_db:init(?JSON_DIR, [{backend, json}]).

reopen_json() ->
    mgmtd_cfg_db:init(?JSON_DIR, [{backend, json}]).

commit_set(Path) ->
    Txn = mgmtd:txn_new(),
    {ok, SchemaPath} = mgmtd_schema:lookup_path(Path),
    {ok, Txn2} = mgmtd:txn_set(Txn, SchemaPath),
    mgmtd:txn_commit(Txn2).
