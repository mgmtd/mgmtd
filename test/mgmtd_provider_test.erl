%%%-------------------------------------------------------------------
%%% @doc Tests for operational-data provider callbacks.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_provider_test).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% Schema load / inheritance
%%--------------------------------------------------------------------
schema_callback_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd:load_function_schema(fun mgmtd_test_provider:schema/0),
    try
        #{config := false, data_callback := mgmtd_test_provider} =
            mgmtd_schema:lookup(["status"]),
        ?assertEqual(mgmtd_test_provider,
                     mgmtd_schema:data_callback(["status"])),
        %% Inherited onto list and leaf descendants
        ?assertEqual(mgmtd_test_provider,
                     mgmtd_schema:data_callback(["status", "uptime"])),
        ?assertEqual(mgmtd_test_provider,
                     mgmtd_schema:data_callback(["status", "interfaces"])),
        ?assertEqual(mgmtd_test_provider,
                     mgmtd_schema:data_callback(["status", "interfaces", "mtu"])),
        ?assertEqual(mgmtd_test_provider,
                     mgmtd_schema:data_callback(["status", "tags"])),
        %% Operational node with no provider stays unset
        #{config := false, data_callback := undefined} =
            mgmtd_schema:lookup(["orphan"]),
        ?assertEqual(undefined, mgmtd_schema:data_callback(["orphan", "n"]))
    after
        mgmtd:remove_schema()
    end.

config_list_keeps_mgmtd_callback_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    try
        #{config := true, data_callback := mgmtd} =
            mgmtd_schema:lookup(["server", "servers"]),
        #{config := true, data_callback := mgmtd} =
            mgmtd_schema:lookup(["client", "clients"])
    after
        mgmtd:remove_schema()
    end.

json_callback_opt_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    File = "test/json_schema_operational.json",
    ok = file:write_file(File, <<"{
        \"$schema\": \"http://json-schema.org/draft-07/schema#\",
        \"type\": \"object\",
        \"properties\": {
            \"uptime\": {\"type\": \"string\", \"description\": \"Uptime\"}
        }
    }">>),
    try
        ok = mgmtd:load_json_schema(File, #{namespace => jsonoper,
                                            callback => mgmtd_test_provider}),
        ?assertEqual(mgmtd_test_provider,
                     mgmtd_schema:data_callback(["jsonoper", "uptime"])),
        ?assertEqual({ok, "9s"}, mgmtd:lookup(["jsonoper", "uptime"]))
    after
        file:delete(File),
        mgmtd:remove_schema(jsonoper)
    end.

%%--------------------------------------------------------------------
%% Lookup / list_keys / show
%%--------------------------------------------------------------------
setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd:load_function_schema(fun mgmtd_test_provider:schema/0),
    ok.

teardown(_) ->
    ok = mgmtd:remove_schema(),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

provider_lookup_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun lookup_leaf/0,
      fun lookup_leaf_list/0,
      fun lookup_missing_leaf/0,
      fun lookup_container/0,
      fun lookup_list_keys/0,
      fun lookup_list_item_children/0,
      fun lookup_key_leaf_from_path/0,
      fun lookup_compound_list/0,
      fun list_keys_match/0,
      fun list_keys_via_mgmtd/0,
      fun no_provider_errors/0,
      fun show_operational_tree/0,
      fun show_list_item/0]}.

lookup_leaf() ->
    ?assertEqual({ok, "1d4h"}, mgmtd:lookup(["status", "uptime"])),
    ?assertEqual({ok, "up"},
                 mgmtd:lookup(["status", "interfaces", {"eth0"}, "state"])),
    ?assertEqual({ok, 1500},
                 mgmtd:lookup(["status", "interfaces", {"eth0"}, "mtu"])).

lookup_leaf_list() ->
    ?assertEqual({ok, ["core", "edge"]}, mgmtd:lookup(["status", "tags"])).

lookup_missing_leaf() ->
    ?assertEqual({ok, undefined},
                 mgmtd:lookup(["status", "interfaces", {"eth9"}, "state"])).

lookup_container() ->
    {ok, Names} = mgmtd:lookup(["status"]),
    ?assertEqual(["interfaces", "peers", "tags", "uptime"], lists:sort(Names)).

lookup_list_keys() ->
    {ok, Keys} = mgmtd:lookup(["status", "interfaces"]),
    ?assertEqual([{"eth0"}, {"eth1"}], lists:sort(Keys)).

lookup_list_item_children() ->
    {ok, Names} = mgmtd:lookup(["status", "interfaces", {"eth0"}]),
    ?assertEqual(["mtu", "name", "state"], lists:sort(Names)).

lookup_key_leaf_from_path() ->
    ?assertEqual({ok, "eth0"},
                 mgmtd:lookup(["status", "interfaces", {"eth0"}, "name"])).

lookup_compound_list() ->
    Key = {{127,0,0,1}, 8080},
    ?assertEqual({ok, [Key]}, mgmtd:lookup(["status", "peers"])),
    ?assertEqual({ok, "established"},
                 mgmtd:lookup(["status", "peers", Key, "state"])),
    ?assertEqual({ok, {127,0,0,1}},
                 mgmtd:lookup(["status", "peers", Key, "host"])),
    ?assertEqual({ok, 8080},
                 mgmtd:lookup(["status", "peers", Key, "port"])).

list_keys_match() ->
    ?assertEqual({ok, [{"eth0"}, {"eth1"}]},
                 mgmtd_provider:list_keys(["status", "interfaces"], '$1')),
    ?assertEqual({ok, ["eth0", "eth1"]},
                 mgmtd_provider:list_keys(["status", "interfaces"], {'$1'})),
    ?assertEqual({ok, [{127,0,0,1}]},
                 mgmtd_provider:list_keys(["status", "peers"], {'$1', '_'})),
    ?assertEqual({ok, [8080]},
                 mgmtd_provider:list_keys(["status", "peers"],
                                          {{127,0,0,1}, '$1'})).

list_keys_via_mgmtd() ->
    ?assertEqual([{"eth0"}, {"eth1"}],
                 lists:sort(mgmtd:list_keys(undefined,
                                            ["status", "interfaces"], '$1'))).

no_provider_errors() ->
    ?assertEqual({error, no_data_callback}, mgmtd:lookup(["orphan", "n"])).

show_operational_tree() ->
    {ok, Path} = mgmtd_schema:lookup_path(["status"]),
    {ok, Tree} = mgmtd:txn_show(undefined, Path),
    Status = proplists:get_value("status", Tree),
    ?assertEqual({value, "1d4h"}, proplists:get_value("uptime", Status)),
    ?assertEqual({value, ["core", "edge"]}, proplists:get_value("tags", Status)),
    Ifaces = proplists:get_value("interfaces", Status),
    Eth0 = proplists:get_value({"eth0"}, Ifaces),
    ?assertEqual({value, "eth0"}, proplists:get_value("name", Eth0)),
    ?assertEqual({value, "up"}, proplists:get_value("state", Eth0)),
    ?assertEqual({value, 1500}, proplists:get_value("mtu", Eth0)).

show_list_item() ->
    {ok, Path} = mgmtd_schema:lookup_path(["status", "interfaces", {"eth1"}]),
    {ok, Tree} = mgmtd:txn_show(undefined, Path),
    ?assertEqual({value, "down"}, proplists:get_value("state", Tree)),
    ?assertEqual({value, "eth1"}, proplists:get_value("name", Tree)).
