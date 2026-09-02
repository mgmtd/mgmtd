%%%-------------------------------------------------------------------
%%% @doc Tests for the sys.config subtree-codec hook.
%%%
%%% Uses `mgmtd_test_codec`, a generic tagged-tuple adapter. Application
%%% codecs are not part of mgmtd.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_codec_test).

-include_lib("eunit/include/eunit.hrl").

-define(DB_DIR, "test_db_codec").

-define(WIRE,
        [{default,
          [{items,
            [{item, a, #{n => 1}},
             {item, b, #{n => 2}}]}]}]).

%%--------------------------------------------------------------------
%% Pure codec
%%--------------------------------------------------------------------
codec_term_test_() ->
    [fun export_packs_tagged_tuples/0,
     fun import_unpacks_tagged_tuples/0,
     fun roundtrip_default_form/0,
     fun import_rejects_unknown_tag/0].

export_packs_tagged_tuples() ->
    Default = [[{name, "a"}, {n, 1}], [{name, "b"}, {n, 2}]],
    ?assertEqual([{item, a, #{n => 1}}, {item, b, #{n => 2}}],
                 mgmtd_test_codec:export(Default)).

import_unpacks_tagged_tuples() ->
    [{NameA, NA}, {NameB, NB}] =
        [{proplists:get_value(name, P), proplists:get_value(n, P)}
         || P <- mgmtd_test_codec:import([{item, a, #{n => 1}},
                                          {item, b, #{n => 2}}])],
    ?assertEqual({"a", 1}, {NameA, NA}),
    ?assertEqual({"b", 2}, {NameB, NB}).

roundtrip_default_form() ->
    Default = [[{name, "a"}, {n, 1}]],
    Back = mgmtd_test_codec:import(mgmtd_test_codec:export(Default)),
    ?assertEqual(lists:sort(hd(Default)), lists:sort(hd(Back))).

import_rejects_unknown_tag() ->
    ?assertThrow({import_error, {unsupported_item, {other, x}}},
                 mgmtd_test_codec:import([{other, x}])).

%%--------------------------------------------------------------------
%% Schema load
%%--------------------------------------------------------------------
schema_codec_opt_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd:load_function_schema(fun mgmtd_test_codec:schema/0,
                                    #{config => true}),
    try
        #{opts := Opts, node_type := list, key_names := ["name"]} =
            mgmtd_schema:lookup(["items"]),
        ?assertEqual(mgmtd_test_codec, mgmtd_schema:codec(["items"])),
        ?assertEqual({codec, mgmtd_test_codec}, lists:keyfind(codec, 1, Opts)),
        ?assertEqual(undefined, mgmtd_schema:codec(["items", "name"]))
    after
        mgmtd:remove_schema()
    end.

%%--------------------------------------------------------------------
%% Backend integration
%%--------------------------------------------------------------------
setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, sys_config}]),
    ok = mgmtd:load_function_schema(fun mgmtd_test_codec:schema/0,
                                    #{config => true}),
    ok = mgmtd_cfg_db:init(?DB_DIR, [{backend, sys_config}]),
    ok.

teardown(_) ->
    ok = mgmtd:remove_schema(),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, sys_config}]),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

codec_sys_config_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [fun load_wire_file/0,
      fun commit_writes_wire_shape/0,
      fun reload_from_wire_file/0,
      fun reject_unknown_tag_on_import/0]}.

load_wire_file() ->
    ok = write_wire_file(),
    ok = reopen(),
    assert_lookups().

commit_writes_wire_shape() ->
    {ok, Txn} = commit_set(["items", {"a"}, "n", "1"]),
    {ok, _} = txn_set_commit(Txn, ["items", {"b"}, "n", "2"]),
    {ok, [Term]} = file:consult(sys_config_file()),
    ?assertEqual(?WIRE, Term).

reload_from_wire_file() ->
    {ok, _} = commit_set(["items", {"a"}, "n", "1"]),
    ok = write_wire_file(),
    ok = reopen(),
    assert_lookups(),
    {ok, [Term]} = file:consult(sys_config_file()),
    ?assertEqual(?WIRE, Term).

reject_unknown_tag_on_import() ->
    Term = [{default, [{items, [{other, x}]}]}],
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, sys_config}]),
    ok = filelib:ensure_dir(sys_config_file()),
    ok = file:write_file(sys_config_file(),
                         mgmtd_cfg_db_sys_config:format_consult(Term)),
    ?assertMatch({error, {unsupported_item, {other, x}}},
                 mgmtd_cfg_db:init(?DB_DIR, [{backend, sys_config}])).

%%--------------------------------------------------------------------
assert_lookups() ->
    ?assertEqual({ok, "a"}, mgmtd:lookup(["items", {"a"}, "name"])),
    ?assertEqual({ok, 1}, mgmtd:lookup(["items", {"a"}, "n"])),
    ?assertEqual({ok, "b"}, mgmtd:lookup(["items", {"b"}, "name"])),
    ?assertEqual({ok, 2}, mgmtd:lookup(["items", {"b"}, "n"])),
    {ok, Keys} = mgmtd:lookup(["items"]),
    ?assertEqual([{"a"}, {"b"}], lists:sort(Keys)).

write_wire_file() ->
    ok = filelib:ensure_dir(sys_config_file()),
    ok = file:write_file(sys_config_file(),
                         mgmtd_cfg_db_sys_config:format_consult(?WIRE)).

sys_config_file() ->
    filename:join(?DB_DIR, "sys.config").

reopen() ->
    case ets:info(mgmtd_cfg) of
        undefined -> ok;
        _ -> ets:delete(mgmtd_cfg)
    end,
    mgmtd_cfg_db:init(?DB_DIR, [{backend, sys_config}]).

commit_set(Path) ->
    Txn = mgmtd:txn_new(),
    txn_set_commit(Txn, Path).

txn_set_commit(Txn, Path) ->
    {ok, SchemaPath} = mgmtd_schema:lookup_path(Path),
    {ok, Txn2} = mgmtd:txn_set(Txn, SchemaPath),
    mgmtd:txn_commit(Txn2).
