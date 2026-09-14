%%%-------------------------------------------------------------------
%%% @doc Eunit tests for the JSON file backend.
%%%
%%% Nested JSON tree of the committed config. No sys.config codecs,
%%% OTP-app wrapping, or unmatched-section merge.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_json_db_test).

-include_lib("eunit/include/eunit.hrl").

-define(DB_DIR, "test_db_json").
-define(NS_DIR, "test_db_json_ns").
-define(CODEC_DIR, "test_db_json_codec").
-define(ORD_DIR, "test_db_json_ordered").
-define(TY_DIR, "test_db_json_types").

%%--------------------------------------------------------------------
%% Pretty printer (no database)
%%--------------------------------------------------------------------
encode_pretty_test_() ->
    [fun pretty_roundtrips_object/0,
     fun pretty_has_newlines/0,
     fun pretty_empty_object/0].

pretty_roundtrips_object() ->
    Term = #{<<"server">> =>
                 #{<<"servers">> =>
                       [#{<<"name">> => <<"web1">>, <<"port">> => 81}]}},
    Bin = mgmtd_json:encode_pretty(Term),
    ?assertEqual(Term, mgmtd_json:decode(Bin)).

pretty_has_newlines() ->
    Bin = mgmtd_json:encode_pretty(#{<<"a">> => 1}),
    ?assertNotEqual(nomatch, binary:match(Bin, <<"\n">>)),
    ?assertEqual($\n, binary:last(Bin)).

pretty_empty_object() ->
    Bin = mgmtd_json:encode_pretty(#{}),
    ?assertEqual(#{}, mgmtd_json:decode(Bin)).

%%--------------------------------------------------------------------
%% Backend integration
%%--------------------------------------------------------------------
setup() ->
    start_mgmtd(),
    ok = mgmtd:remove_schema(),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, json}]),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ok = mgmtd_cfg_db:init(?DB_DIR, [{backend, json}]),
    ok.

teardown(_) ->
    ok = mgmtd:remove_schema(),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, json}]),
    ok.

ns_setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?NS_DIR, [{backend, json}]),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                    #{namespace => example}),
    ok = mgmtd_cfg_db:init(?NS_DIR, [{backend, json}]),
    ok.

ns_teardown(_) ->
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?NS_DIR, [{backend, json}]),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

json_db_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [fun empty_file_is_json_object/0,
      fun commit_writes_nested_json/0,
      fun reload_from_file/0,
      fun compound_key_roundtrip/0,
      fun enum_and_defaults_roundtrip/0,
      fun load_handwritten_json/0,
      fun show_from_operational_mode/0,
      fun unknown_keys_skipped/0,
      fun unknown_keys_dropped_on_rewrite/0,
      fun invalid_schema_value_still_rejected/0,
      fun invalid_json_rejected/0]}.

namespace_json_test_() ->
    {setup, fun ns_setup/0, fun ns_teardown/1,
     [fun prefixes_are_root_objects/0]}.

empty_file_is_json_object() ->
    ?assertEqual(#{}, read_json(?DB_DIR)).

commit_writes_nested_json() ->
    {ok, _} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    Json = read_json(?DB_DIR),
    Server = maps:get(<<"server">>, Json),
    [Item] = maps:get(<<"servers">>, Server),
    ?assertEqual(<<"web1">>, maps:get(<<"name">>, Item)),
    ?assertEqual(81, maps:get(<<"port">>, Item)),
    ?assertEqual(undefined, maps:get(<<"default">>, Json, undefined)).

reload_from_file() ->
    {ok, _} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"web1"}, "port"])),
    ok = reopen(?DB_DIR),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"web1"}, "port"])),
    ?assertEqual({ok, "web1"}, mgmtd:lookup(["server", "servers", {"web1"}, "name"])),
    ?assertEqual({ok, [{"web1"}]}, mgmtd:lookup(["server", "servers"])).

compound_key_roundtrip() ->
    {ok, _} = commit_set(["client", "clients", {"127.0.0.1", "82"}, "name", "Name"]),
    ItemPath = ["client", "clients", {"127.0.0.1", "82"}],
    ?assertEqual({ok, "Name"}, mgmtd:lookup(ItemPath ++ ["name"])),
    ?assertEqual({ok, {127,0,0,1}}, mgmtd:lookup(ItemPath ++ ["host"])),
    ?assertEqual({ok, 82}, mgmtd:lookup(ItemPath ++ ["port"])),
    Json = read_json(?DB_DIR),
    [Item] = nested([<<"client">>, <<"clients">>], Json),
    ?assertEqual(<<"Name">>, maps:get(<<"name">>, Item)),
    ?assertEqual(<<"127.0.0.1">>, maps:get(<<"host">>, Item)),
    ?assertEqual(82, maps:get(<<"port">>, Item)),
    ok = reopen(?DB_DIR),
    ?assertEqual({ok, "Name"}, mgmtd:lookup(ItemPath ++ ["name"])),
    ?assertEqual({ok, {127,0,0,1}}, mgmtd:lookup(ItemPath ++ ["host"])),
    ?assertEqual({ok, 82}, mgmtd:lookup(ItemPath ++ ["port"])),
    ?assertEqual({ok, [{"127.0.0.1", "82"}]}, mgmtd:lookup(["client", "clients"])).

enum_and_defaults_roundtrip() ->
    {ok, _} = commit_set(["interface", "speed", "1GbE"]),
    {ok, _} = commit_set(["server", "servers", {"web1"}, "port", "9"]),
    ok = reopen(?DB_DIR),
    ?assertEqual({ok, "1GbE"}, mgmtd:lookup(["interface", "speed"])),
    ?assertEqual({ok, "127.0.0.1"},
                 mgmtd:lookup(["server", "servers", {"web1"}, "host"])),
    Json = read_json(?DB_DIR),
    Interface = maps:get(<<"interface">>, Json),
    ?assertEqual(<<"1GbE">>, maps:get(<<"speed">>, Interface)).

show_from_operational_mode() ->
    ?assertEqual({ok, []}, mgmtd:txn_show(undefined, [])),
    {ok, Txn} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    {ok, FromTxn} = mgmtd:txn_show(Txn, []),
    {ok, FromCommitted} = mgmtd:txn_show(undefined, []),
    ?assertEqual(FromTxn, FromCommitted),
    ?assertMatch([{"server", _}], FromCommitted).

load_handwritten_json() ->
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, json}]),
    ok = filelib:ensure_dir(filename:join(?DB_DIR, "config.json")),
    Term = #{<<"interface">> => #{<<"speed">> => <<"1GbE">>},
             <<"server">> =>
                 #{<<"servers">> =>
                       [#{<<"name">> => <<"fromfile">>,
                          <<"host">> => <<"10.0.0.1">>,
                          <<"port">> => 9999}]}},
    ok = file:write_file(json_file(?DB_DIR), mgmtd_json:encode_pretty(Term)),
    ok = mgmtd_cfg_db:init(?DB_DIR, [{backend, json}]),
    ?assertEqual({ok, "1GbE"}, mgmtd:lookup(["interface", "speed"])),
    Item = ["server", "servers", {"fromfile"}],
    ?assertEqual({ok, "fromfile"}, mgmtd:lookup(Item ++ ["name"])),
    ?assertEqual({ok, {10,0,0,1}}, mgmtd:lookup(Item ++ ["host"])),
    ?assertEqual({ok, 9999}, mgmtd:lookup(Item ++ ["port"])).

unknown_keys_skipped() ->
    Term = #{<<"interface">> => #{<<"speed">> => <<"1GbE">>,
                                  <<"mtu">> => 1500},
             <<"orphan">> => #{<<"x">> => 1},
             <<"server">> =>
                 #{<<"servers">> =>
                       [#{<<"name">> => <<"web1">>,
                          <<"port">> => 81,
                          <<"note">> => <<"keep me">>}]}},
    ok = load_file(Term),
    ?assertEqual({ok, "1GbE"}, mgmtd:lookup(["interface", "speed"])),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"web1"}, "port"])),
    ?assertEqual({error, unknown_schema_path}, mgmtd:lookup(["orphan"])),
    ?assertEqual({error, unknown_schema_path},
                 mgmtd:lookup(["interface", "mtu"])),
    {ok, Show} = mgmtd:txn_show(undefined, []),
    ?assertEqual(undefined, proplists:get_value("orphan", Show)),
    Iface = proplists:get_value("interface", Show),
    ?assertEqual(undefined, proplists:get_value("mtu", Iface)).

unknown_keys_dropped_on_rewrite() ->
    Term = #{<<"interface">> => #{<<"speed">> => <<"1GbE">>,
                                  <<"mtu">> => 1500},
             <<"orphan">> => #{<<"x">> => 1}},
    ok = load_file(Term),
    {ok, _} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    Json = read_json(?DB_DIR),
    ?assertEqual(undefined, maps:get(<<"orphan">>, Json, undefined)),
    Interface = maps:get(<<"interface">>, Json),
    ?assertEqual(<<"1GbE">>, maps:get(<<"speed">>, Interface)),
    ?assertEqual(undefined, maps:get(<<"mtu">>, Interface, undefined)).

invalid_schema_value_still_rejected() ->
    Term = #{<<"interface">> => #{<<"speed">> => <<"nope">>}},
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, json}]),
    ok = filelib:ensure_dir(json_file(?DB_DIR)),
    ok = file:write_file(json_file(?DB_DIR), mgmtd_json:encode_pretty(Term)),
    ?assertEqual({error, "Unknown enum value"},
                 mgmtd_cfg_db:init(?DB_DIR, [{backend, json}])).

invalid_json_rejected() ->
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, json}]),
    ok = filelib:ensure_dir(json_file(?DB_DIR)),
    ok = file:write_file(json_file(?DB_DIR), <<"not json">>),
    ?assertMatch({error, {json_decode, _}},
                 mgmtd_cfg_db:init(?DB_DIR, [{backend, json}])).

prefixes_are_root_objects() ->
    {ok, Txn} = commit_set(["server", "servers", {"def1"}, "port", "81"]),
    {ok, _} = txn_set_commit(Txn, ["example", "server", "servers", {"ex1"}, "port", "82"]),
    Json = read_json(?NS_DIR),
    DefaultServers = nested([<<"server">>, <<"servers">>], Json),
    ExampleServers = nested([<<"example">>, <<"server">>, <<"servers">>], Json),
    ?assertEqual(81, maps:get(<<"port">>, hd(DefaultServers))),
    ?assertEqual(82, maps:get(<<"port">>, hd(ExampleServers))),
    ?assertEqual(undefined, maps:get(<<"default">>, Json, undefined)),
    ok = reopen(?NS_DIR, json),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"def1"}, "port"])),
    ?assertEqual({ok, 82},
                 mgmtd:lookup(["example", "server", "servers", {"ex1"}, "port"])).

%%--------------------------------------------------------------------
%% Codecs are sys.config-only: JSON dumps the native nested tree.
%%--------------------------------------------------------------------
codec_setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?CODEC_DIR, [{backend, json}]),
    ok = mgmtd:load_function_schema(fun mgmtd_test_codec:schema/0,
                                    #{config => true}),
    ok = mgmtd_cfg_db:init(?CODEC_DIR, [{backend, json}]),
    ok.

codec_teardown(_) ->
    ok = mgmtd:remove_schema(),
    ok = mgmtd_cfg_db:remove_db(?CODEC_DIR, [{backend, json}]),
    ok.

codec_not_applied_test_() ->
    {setup, fun codec_setup/0, fun codec_teardown/1,
     [fun json_dumps_objects_not_tagged_tuples/0]}.

json_dumps_objects_not_tagged_tuples() ->
    {ok, Txn} = commit_set(["items", {"a"}, "n", "1"]),
    {ok, _} = txn_set_commit(Txn, ["items", {"b"}, "n", "2"]),
    Json = read_json(?CODEC_DIR),
    Items = maps:get(<<"items">>, Json),
    ?assertEqual(2, length(Items)),
    Names = lists:sort([maps:get(<<"name">>, I) || I <- Items]),
    ?assertEqual([<<"a">>, <<"b">>], Names),
    ok = reopen(?CODEC_DIR, json),
    ?assertEqual({ok, 1}, mgmtd:lookup(["items", {"a"}, "n"])),
    ?assertEqual({ok, 2}, mgmtd:lookup(["items", {"b"}, "n"])).

%%--------------------------------------------------------------------
%% ordered-by user is JSON array order
%%--------------------------------------------------------------------
ordered_setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?ORD_DIR, [{backend, json}]),
    ok = mgmtd:load_yang_module("test/yang/example-ordered.yang"),
    ok = mgmtd_cfg_db:init(?ORD_DIR, [{backend, json}]),
    ok.

ordered_teardown(_) ->
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?ORD_DIR, [{backend, json}]),
    ok.

ordered_json_test_() ->
    {setup, fun ordered_setup/0, fun ordered_teardown/1,
     [fun user_order_is_array_order/0]}.

user_order_is_array_order() ->
    Txn0 = mgmtd:txn_new(),
    {ok, Pz} = mgmtd_schema:lookup_path(["ord", "acl", "rule", {"z"}, "action", "drop"]),
    {ok, Pa} = mgmtd_schema:lookup_path(["ord", "acl", "rule", {"a"}, "action", "permit"]),
    {ok, Pm} = mgmtd_schema:lookup_path(["ord", "acl", "rule", {"m"}, "action", "drop"]),
    {ok, Txn1} = mgmtd:txn_set(Txn0, Pz),
    {ok, Txn2} = mgmtd:txn_set(Txn1, Pa),
    {ok, Txn3} = mgmtd:txn_set(Txn2, Pm),
    {ok, _} = mgmtd:txn_commit(Txn3),
    Json = read_json(?ORD_DIR),
    Rules = nested([<<"ord">>, <<"acl">>, <<"rule">>], Json),
    ?assertEqual([<<"z">>, <<"a">>, <<"m">>],
                 [maps:get(<<"name">>, R) || R <- Rules]),
    ok = reopen(?ORD_DIR, json),
    ?assertEqual([{"z"}, {"a"}, {"m"}],
                 [K || K <- mgmtd_cfg_db:list_keys(["ord", "acl", "rule"]),
                       is_tuple(K)]).

%%--------------------------------------------------------------------
%% YANG scalar encoding
%%--------------------------------------------------------------------
types_setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?TY_DIR, [{backend, json}]),
    ok = mgmtd:load_yang_module("test/yang/example-types.yang"),
    ok = mgmtd_cfg_db:init(?TY_DIR, [{backend, json}]),
    ok.

types_teardown(_) ->
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?TY_DIR, [{backend, json}]),
    ok.

yang_types_json_test_() ->
    {setup, fun types_setup/0, fun types_teardown/1,
     [fun yang_scalars_roundtrip/0]}.

yang_scalars_roundtrip() ->
    Paths = [["ty", "types", "flags", "up down"],
             ["ty", "types", "ratio", "1.5"],
             ["ty", "types", "marker", ""],
             ["ty", "types", "blob", "YWI="]],
    lists:foldl(
      fun(Path, ok) ->
              {ok, _} = commit_set(Path),
              ok
      end, ok, Paths),
    Json = nested([<<"ty">>, <<"types">>], read_json(?TY_DIR)),
    ?assertEqual(<<"up down">>, maps:get(<<"flags">>, Json)),
    ?assertEqual(<<"1.5">>, maps:get(<<"ratio">>, Json)),
    ?assertEqual([null], maps:get(<<"marker">>, Json)),
    ?assertEqual(<<"YWI=">>, maps:get(<<"blob">>, Json)),
    ok = reopen(?TY_DIR, json),
    ?assertEqual({ok, ["up", "down"]}, mgmtd:lookup(["ty", "types", "flags"])),
    ?assertEqual({ok, "1.5"}, mgmtd:lookup(["ty", "types", "ratio"])),
    ?assertEqual({ok, empty}, mgmtd:lookup(["ty", "types", "marker"])),
    ?assertEqual({ok, "YWI="}, mgmtd:lookup(["ty", "types", "blob"])).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------
json_file(Dir) ->
    filename:join(Dir, "config.json").

read_json(Dir) ->
    {ok, Bin} = file:read_file(json_file(Dir)),
    mgmtd_json:decode(Bin).

reopen(Dir) ->
    reopen(Dir, json).

reopen(Dir, Backend) ->
    case ets:info(mgmtd_cfg) of
        undefined -> ok;
        _ -> ets:delete(mgmtd_cfg)
    end,
    mgmtd_cfg_db:init(Dir, [{backend, Backend}]).

commit_set(Path) ->
    Txn = mgmtd:txn_new(),
    txn_set_commit(Txn, Path).

txn_set_commit(Txn, Path) ->
    {ok, SchemaPath} = mgmtd_schema:lookup_path(Path),
    {ok, Txn2} = mgmtd:txn_set(Txn, SchemaPath),
    mgmtd:txn_commit(Txn2).

load_file(Term) ->
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, json}]),
    ok = filelib:ensure_dir(json_file(?DB_DIR)),
    ok = file:write_file(json_file(?DB_DIR), mgmtd_json:encode_pretty(Term)),
    mgmtd_cfg_db:init(?DB_DIR, [{backend, json}]).

nested(Path, Tree) ->
    lists:foldl(fun(Name, Acc) -> maps:get(Name, Acc) end, Tree, Path).
