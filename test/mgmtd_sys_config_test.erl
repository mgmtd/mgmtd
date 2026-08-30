%%%-------------------------------------------------------------------
%%% @doc Eunit tests for the sys.config file backend.
%%%
%%% The on-disk file must always be readable by file:consult/1.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_sys_config_test).

-include_lib("eunit/include/eunit.hrl").

-define(DB_DIR, "test_db_sys_config").
-define(NS_DIR, "test_db_sys_config_ns").

%%--------------------------------------------------------------------
%% Consult-safe printer (no database)
%%--------------------------------------------------------------------
format_consult_test_() ->
    [fun format_is_consultable/0,
     fun format_does_not_truncate_deep_terms/0,
     fun format_round_trips_unicode/0,
     fun format_quotes_special_atoms/0,
     fun format_empty_list/0].

format_is_consultable() ->
    Term = [{default, [{server, [{servers, [[{name, "web1"}, {port, 80}]]}]}]},
            {example, [{interface, [{speed, "1GbE"}]}]}],
    assert_consult_roundtrip(Term).

format_does_not_truncate_deep_terms() ->
    Term = deep_term(40, leaf),
    Bin = iolist_to_binary(mgmtd_cfg_db_sys_config:format_consult(Term)),
    ?assertEqual(nomatch, binary:match(Bin, <<"...">>)),
    assert_consult_roundtrip(Term).

format_round_trips_unicode() ->
    Term = [{default, [{note, "café 日本語"}]}],
    assert_consult_roundtrip(Term).

format_quotes_special_atoms() ->
    Term = [{'1GbE', true}, {'foo-bar', [a, b]}],
    assert_consult_roundtrip(Term).

format_empty_list() ->
    assert_consult_roundtrip([]).

deep_term(0, Acc) ->
    Acc;
deep_term(N, Acc) ->
    deep_term(N - 1, [{level, Acc}]).

assert_consult_roundtrip(Term) ->
    File = consult_temp_file(),
    ok = file:write_file(File, mgmtd_cfg_db_sys_config:format_consult(Term)),
    try
        ?assertEqual({ok, [Term]}, file:consult(File))
    after
        _ = file:delete(File)
    end.

consult_temp_file() ->
    filename:join("/tmp",
                  "mgmtd_sys_config_" ++ integer_to_list(erlang:unique_integer([positive]))
                  ++ ".config").

%%--------------------------------------------------------------------
%% Backend integration
%%--------------------------------------------------------------------
setup() ->
    start_mgmtd(),
    ok = mgmtd:remove_schema(),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, sys_config}]),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ok = mgmtd_cfg_db:init(?DB_DIR, [{backend, sys_config}]),
    ok.

teardown(_) ->
    ok = mgmtd:remove_schema(),
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, sys_config}]),
    ok.

ns_setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?NS_DIR, [{backend, sys_config}]),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                    #{namespace => example}),
    ok = mgmtd_cfg_db:init(?NS_DIR, [{backend, sys_config}]),
    ok.

ns_teardown(_) ->
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?NS_DIR, [{backend, sys_config}]),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

sys_config_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [fun empty_file_is_consultable/0,
      fun commit_writes_consultable_file/0,
      fun reload_from_file/0,
      fun compound_key_roundtrip/0,
      fun enum_and_defaults_roundtrip/0,
      fun load_handwritten_sys_config/0,
      fun show_from_operational_mode/0]}.

namespace_sys_config_test_() ->
    {setup, fun ns_setup/0, fun ns_teardown/1,
     [fun prefixes_are_application_slots/0]}.

empty_file_is_consultable() ->
    File = sys_config_file(?DB_DIR),
    ?assertEqual({ok, [[]]}, file:consult(File)).

commit_writes_consultable_file() ->
    {ok, _} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    {ok, [Term]} = file:consult(sys_config_file(?DB_DIR)),
    ?assertMatch([{default, _}], Term),
    {default, Tree} = hd(Term),
    Server = proplists:get_value(server, Tree),
    Servers = proplists:get_value(servers, Server),
    [Item] = Servers,
    ?assertEqual("web1", proplists:get_value(name, Item)),
    ?assertEqual(81, proplists:get_value(port, Item)),
    Bin = consult_file_text(sys_config_file(?DB_DIR)),
    ?assertEqual(nomatch, binary:match(Bin, <<"...">>)).

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
    {ok, [Term]} = file:consult(sys_config_file(?DB_DIR)),
    {default, Tree} = hd(Term),
    Clients = proplists:get_value(
                clients, proplists:get_value(client, Tree)),
    [Item] = Clients,
    ?assertEqual("Name", proplists:get_value(name, Item)),
    ?assertEqual({127,0,0,1}, proplists:get_value(host, Item)),
    ?assertEqual(82, proplists:get_value(port, Item)),
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
    %% host was never set; schema default still applies after reload
    ?assertEqual({ok, "127.0.0.1"},
                 mgmtd:lookup(["server", "servers", {"web1"}, "host"])),
    {ok, [Term]} = file:consult(sys_config_file(?DB_DIR)),
    {default, Tree} = hd(Term),
    Interface = proplists:get_value(interface, Tree),
    ?assertEqual("1GbE", proplists:get_value(speed, Interface)).

%% Operational `show configuration` (no txn) against the sys_config
%% ETS table `mgmtd_cfg` — not a leftover named table `cfg`.
show_from_operational_mode() ->
    ?assertEqual({ok, []}, mgmtd:txn_show(undefined, [])),
    {ok, Txn} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    {ok, FromTxn} = mgmtd:txn_show(Txn, []),
    {ok, FromCommitted} = mgmtd:txn_show(undefined, []),
    ?assertEqual(FromTxn, FromCommitted),
    ?assertMatch([{"server", _}], FromCommitted).

load_handwritten_sys_config() ->
    ok = mgmtd_cfg_db:remove_db(?DB_DIR, [{backend, sys_config}]),
    ok = filelib:ensure_dir(filename:join(?DB_DIR, "sys.config")),
    Term =
        [{default,
          [{interface, [{speed, "1GbE"}]},
           {server,
            [{servers,
              [[{name, "fromfile"},
                {host, {10,0,0,1}},
                {port, 9999}]]}]}]}],
    ok = file:write_file(sys_config_file(?DB_DIR),
                         mgmtd_cfg_db_sys_config:format_consult(Term)),
    ?assertEqual({ok, [Term]}, file:consult(sys_config_file(?DB_DIR))),
    ok = mgmtd_cfg_db:init(?DB_DIR, [{backend, sys_config}]),
    ?assertEqual({ok, "1GbE"}, mgmtd:lookup(["interface", "speed"])),
    Item = ["server", "servers", {"fromfile"}],
    ?assertEqual({ok, "fromfile"}, mgmtd:lookup(Item ++ ["name"])),
    ?assertEqual({ok, {10,0,0,1}}, mgmtd:lookup(Item ++ ["host"])),
    ?assertEqual({ok, 9999}, mgmtd:lookup(Item ++ ["port"])).

prefixes_are_application_slots() ->
    {ok, Txn} = commit_set(["server", "servers", {"def1"}, "port", "81"]),
    {ok, _} = txn_set_commit(Txn, ["example", "server", "servers", {"ex1"}, "port", "82"]),
    {ok, [Term]} = file:consult(sys_config_file(?NS_DIR)),
    ?assertEqual(lists:sort([default, example]),
                 lists:sort([P || {P, _} <- Term])),
    Default = proplists:get_value(default, Term),
    Example = proplists:get_value(example, Term),
    ?assertEqual(81, nested([server, servers], Default, port)),
    ?assertEqual(82, nested([server, servers], Example, port)),
    %% Named prefix is not dumped as a fake nested "example" container
    %% inside its own application slot.
    ?assertEqual(undefined, proplists:get_value(example, Example)),
    ok = reopen(?NS_DIR),
    ?assertEqual({ok, 81}, mgmtd:lookup(["server", "servers", {"def1"}, "port"])),
    ?assertEqual({ok, 82},
                 mgmtd:lookup(["example", "server", "servers", {"ex1"}, "port"])).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------
sys_config_file(Dir) ->
    filename:join(Dir, "sys.config").

consult_file_text(File) ->
    {ok, Bin} = file:read_file(File),
    Bin.

reopen(Dir) ->
    %% Keep the file; rebuild the in-memory table from it.
    case ets:info(mgmtd_cfg) of
        undefined -> ok;
        _ -> ets:delete(mgmtd_cfg)
    end,
    mgmtd_cfg_db:init(Dir, [{backend, sys_config}]).

commit_set(Path) ->
    Txn = mgmtd:txn_new(),
    txn_set_commit(Txn, Path).

txn_set_commit(Txn, Path) ->
    {ok, SchemaPath} = mgmtd_schema:lookup_path(Path),
    {ok, Txn2} = mgmtd:txn_set(Txn, SchemaPath),
    mgmtd:txn_commit(Txn2).

nested([ListName], Tree, Leaf) ->
    case proplists:get_value(ListName, Tree) of
        [Item] -> proplists:get_value(Leaf, Item);
        Other -> Other
    end;
nested([Name | Rest], Tree, Leaf) ->
    nested(Rest, proplists:get_value(Name, Tree), Leaf).
