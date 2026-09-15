%%%-------------------------------------------------------------------
%%% @doc Startup store: a separately configured sys.config file that is
%%% read only when the main database does not exist, then used to
%%% create the main store.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_startup_store_test).

-include_lib("eunit/include/eunit.hrl").
-include("../src/mgmtd_schema.hrl").

-define(MNESIA_DIR, "test_db_startup_mnesia").
-define(SYS_DIR, "test_db_startup_sys").
-define(JSON_DIR, "test_db_startup_json").
-define(FILE_DIR, "test_db_startup_files").

%%--------------------------------------------------------------------
%% Suite
%%--------------------------------------------------------------------
startup_store_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [fun load_file_returns_cfg_rows/0,
      fun seed_mnesia_when_main_missing/0,
      fun seed_sys_config_when_main_missing/0,
      fun seed_json_when_main_missing/0,
      fun json_main_seeded_from_sys_config_startup/0,
      fun ignore_startup_when_main_exists/0,
      fun changed_startup_ignored_on_second_start/0,
      fun startup_file_not_rewritten/0,
      fun missing_startup_file_does_not_leave_empty_main/0,
      fun invalid_startup_value_rejected/0,
      fun missing_file_option_rejected/0,
      fun unsupported_startup_backend_rejected/0,
      fun location_opt_reads_sys_config/0,
      fun load_config_db_uses_application_env/0,
      fun namespace_prefixes_in_startup_file/0]}.

setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?MNESIA_DIR, [{backend, mnesia}]),
    ok = mgmtd_cfg_db:remove_db(?SYS_DIR, [{backend, sys_config}]),
    ok = mgmtd_cfg_db:remove_db(?JSON_DIR, [{backend, json}]),
    _ = file:del_dir_r(?FILE_DIR),
    ok = filelib:ensure_dir(filename:join(?FILE_DIR, "dummy")),
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0),
    PrevStartup = application:get_env(mgmtd, startup),
    PrevDb = application:get_env(mgmtd, db),
    application:unset_env(mgmtd, startup),
    application:unset_env(mgmtd, db),
    {PrevStartup, PrevDb}.

teardown({PrevStartup, PrevDb}) ->
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?MNESIA_DIR, [{backend, mnesia}]),
    ok = mgmtd_cfg_db:remove_db(?SYS_DIR, [{backend, sys_config}]),
    ok = mgmtd_cfg_db:remove_db(?JSON_DIR, [{backend, json}]),
    _ = file:del_dir_r(?FILE_DIR),
    restore_env(startup, PrevStartup),
    restore_env(db, PrevDb),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

restore_env(Key, undefined) ->
    application:unset_env(mgmtd, Key);
restore_env(Key, {ok, Val}) ->
    application:set_env(mgmtd, Key, Val).

%%--------------------------------------------------------------------
%% Tests
%%--------------------------------------------------------------------
load_file_returns_cfg_rows() ->
    File = write_factory("factory.config", factory_term()),
    {ok, Rows} = mgmtd_cfg_db_sys_config:load_file(File),
    Paths = [P || #cfg{path = P} <- Rows],
    ?assert(lists:member(["interface", "speed"], Paths)),
    ?assert(lists:member(["server", "servers", {"fromfile"}, "port"], Paths)),
    Port = lists:keyfind(["server", "servers", {"fromfile"}, "port"],
                         #cfg.path, Rows),
    ?assertEqual(9999, Port#cfg.value).

seed_mnesia_when_main_missing() ->
    File = write_factory("mnesia.config", factory_term()),
    ok = init_seed(mnesia, ?MNESIA_DIR, File),
    assert_factory_loaded().

seed_sys_config_when_main_missing() ->
    File = write_factory("sys_main.config", factory_term()),
    ok = init_seed(sys_config, ?SYS_DIR, File),
    assert_factory_loaded(),
    {ok, [Written]} = file:consult(filename:join(?SYS_DIR, "sys.config")),
    Default = proplists:get_value(default, Written),
    Server = proplists:get_value(server, Default),
    [Item] = proplists:get_value(servers, Server),
    ?assertEqual("fromfile", proplists:get_value(name, Item)),
    ?assertEqual(9999, proplists:get_value(port, Item)).

seed_json_when_main_missing() ->
    File = write_factory("json_main.config", factory_term()),
    ok = init_seed(json, ?JSON_DIR, File),
    assert_factory_loaded().

%% Main store is JSON (`config.json`); factory input is a sys.config file.
json_main_seeded_from_sys_config_startup() ->
    File = write_factory("json_from_sys.config", factory_term()),
    {ok, [StartupTerm]} = file:consult(File),
    ok = mgmtd_cfg_db:init(?JSON_DIR,
                           [{backend, json},
                            {startup, [{backend, sys_config}, {file, File}]}]),
    assert_factory_loaded(),
    ?assertEqual(false, filelib:is_regular(filename:join(?JSON_DIR, "sys.config"))),
    ?assertEqual(true, filelib:is_regular(filename:join(?JSON_DIR, "config.json"))),
    Json = read_json(?JSON_DIR),
    ?assertEqual(undefined, maps:get(<<"default">>, Json, undefined)),
    Interface = maps:get(<<"interface">>, Json),
    ?assertEqual(<<"1GbE">>, maps:get(<<"speed">>, Interface)),
    [Item] = nested([<<"server">>, <<"servers">>], Json),
    ?assertEqual(<<"fromfile">>, maps:get(<<"name">>, Item)),
    ?assertEqual(<<"10.0.0.1">>, maps:get(<<"host">>, Item)),
    ?assertEqual(9999, maps:get(<<"port">>, Item)),
    %% Startup file stays a sys.config term; it is not rewritten as JSON.
    ?assertEqual({ok, [StartupTerm]}, file:consult(File)),
    %% Later starts use the JSON main store, not the factory file.
    Other =
        [{default,
          [{server,
            [{servers, [[{name, "other"}, {port, 1234}]]}]}]}],
    ok = file:write_file(File, mgmtd_cfg_db_sys_config:format_consult(Other)),
    ok = reopen_json(?JSON_DIR),
    assert_factory_loaded(),
    ?assertEqual({ok, [{"fromfile"}]}, mgmtd:lookup(["server", "servers"])).

ignore_startup_when_main_exists() ->
    ok = mgmtd_cfg_db:init(?MNESIA_DIR, [{backend, mnesia}]),
    {ok, _} = commit_set(["server", "servers", {"web1"}, "port", "81"]),
    File = write_factory("ignored.config", factory_term()),
    ok = mgmtd_cfg_db:init(?MNESIA_DIR,
                           [{backend, mnesia}, {startup, startup_opts(File)}]),
    ?assertEqual({ok, 81},
                 mgmtd:lookup(["server", "servers", {"web1"}, "port"])),
    ?assertEqual({ok, [{"web1"}]}, mgmtd:lookup(["server", "servers"])).

changed_startup_ignored_on_second_start() ->
    File = write_factory("once.config", factory_term()),
    ok = init_seed(mnesia, ?MNESIA_DIR, File),
    Other =
        [{default,
          [{server,
            [{servers, [[{name, "other"}, {port, 1234}]]}]}]}],
    ok = file:write_file(File, mgmtd_cfg_db_sys_config:format_consult(Other)),
    ok = mgmtd_cfg_db:init(?MNESIA_DIR,
                           [{backend, mnesia}, {startup, startup_opts(File)}]),
    assert_factory_loaded(),
    ?assertEqual({ok, [{"fromfile"}]}, mgmtd:lookup(["server", "servers"])).

startup_file_not_rewritten() ->
    File = write_factory("readonly.config", factory_term()),
    {ok, Original} = file:read_file(File),
    ok = init_seed(mnesia, ?MNESIA_DIR, File),
    {ok, After} = file:read_file(File),
    ?assertEqual(Original, After).

missing_startup_file_does_not_leave_empty_main() ->
    File = filename:join(?FILE_DIR, "missing.config"),
    ?assertEqual({error, {startup_file_missing, File}},
                 mgmtd_cfg_db:init(?MNESIA_DIR,
                                   [{backend, mnesia},
                                    {startup, startup_opts(File)}])),
    ok = file:write_file(File, mgmtd_cfg_db_sys_config:format_consult(factory_term())),
    ok = init_seed(mnesia, ?MNESIA_DIR, File),
    assert_factory_loaded().

invalid_startup_value_rejected() ->
    Bad = [{default, [{interface, [{speed, "nope"}]}]}],
    File = write_factory("bad.config", Bad),
    ?assertEqual({error, "Unknown enum value"},
                 mgmtd_cfg_db:init(?MNESIA_DIR,
                                   [{backend, mnesia},
                                    {startup, startup_opts(File)}])),
    Good = write_factory("good.config", factory_term()),
    ok = init_seed(mnesia, ?MNESIA_DIR, Good),
    assert_factory_loaded().

missing_file_option_rejected() ->
    ?assertEqual({error, {invalid_startup, no_file}},
                 mgmtd_cfg_db:init(?MNESIA_DIR,
                                   [{backend, mnesia},
                                    {startup, [{backend, sys_config}]}])).

unsupported_startup_backend_rejected() ->
    ?assertEqual({error, {unsupported_startup_backend, json}},
                 mgmtd_cfg_db:init(?MNESIA_DIR,
                                   [{backend, mnesia},
                                    {startup, [{backend, json},
                                               {file, "x.config"}]}])).

location_opt_reads_sys_config() ->
    Loc = filename:join(?FILE_DIR, "loc"),
    ok = filelib:ensure_dir(filename:join(Loc, "sys.config")),
    ok = file:write_file(filename:join(Loc, "sys.config"),
                         mgmtd_cfg_db_sys_config:format_consult(factory_term())),
    ok = mgmtd_cfg_db:init(?MNESIA_DIR,
                           [{backend, mnesia},
                            {startup, [{backend, sys_config},
                                       {location, Loc}]}]),
    assert_factory_loaded().

load_config_db_uses_application_env() ->
    File = write_factory("env.config", factory_term()),
    application:set_env(mgmtd, db, [{backend, mnesia}]),
    application:set_env(mgmtd, startup, startup_opts(File)),
    ok = mgmtd:load_config_db(?MNESIA_DIR),
    assert_factory_loaded().

namespace_prefixes_in_startup_file() ->
    ok = mgmtd:load_function_schema(fun mgmtd_test_schema:cfg_schema/0,
                                    #{namespace => example}),
    Term =
        [{default,
          [{server, [{servers, [[{name, "def1"}, {port, 81}]]}]}]},
         {example,
          [{server, [{servers, [[{name, "ex1"}, {port, 82}]]}]}]}],
    File = write_factory("ns.config", Term),
    ok = init_seed(mnesia, ?MNESIA_DIR, File),
    ?assertEqual({ok, 81},
                 mgmtd:lookup(["server", "servers", {"def1"}, "port"])),
    ?assertEqual({ok, 82},
                 mgmtd:lookup(["example", "server", "servers", {"ex1"}, "port"])).

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------
factory_term() ->
    [{default,
      [{interface, [{speed, "1GbE"}]},
       {server,
        [{servers,
          [[{name, "fromfile"},
            {host, {10, 0, 0, 1}},
            {port, 9999}]]}]}]}].

write_factory(Name, Term) ->
    File = filename:join(?FILE_DIR, Name),
    ok = filelib:ensure_dir(File),
    ok = file:write_file(File, mgmtd_cfg_db_sys_config:format_consult(Term)),
    File.

startup_opts(File) ->
    [{backend, sys_config}, {file, File}].

init_seed(Backend, Dir, File) ->
    mgmtd_cfg_db:init(Dir, [{backend, Backend}, {startup, startup_opts(File)}]).

assert_factory_loaded() ->
    Item = ["server", "servers", {"fromfile"}],
    ?assertEqual({ok, "fromfile"}, mgmtd:lookup(Item ++ ["name"])),
    ?assertEqual({ok, {10, 0, 0, 1}}, mgmtd:lookup(Item ++ ["host"])),
    ?assertEqual({ok, 9999}, mgmtd:lookup(Item ++ ["port"])),
    ?assertEqual({ok, [{"fromfile"}]}, mgmtd:lookup(["server", "servers"])).

commit_set(Path) ->
    Txn = mgmtd:txn_new(),
    {ok, SchemaPath} = mgmtd_schema:lookup_path(Path),
    {ok, Txn2} = mgmtd:txn_set(Txn, SchemaPath),
    mgmtd:txn_commit(Txn2).

json_file(Dir) ->
    filename:join(Dir, "config.json").

read_json(Dir) ->
    {ok, Bin} = file:read_file(json_file(Dir)),
    mgmtd_json:decode(Bin).

nested(Path, Tree) ->
    lists:foldl(fun(Name, Acc) -> maps:get(Name, Acc) end, Tree, Path).

reopen_json(Dir) ->
    case ets:info(mgmtd_cfg) of
        undefined -> ok;
        _ -> ets:delete(mgmtd_cfg)
    end,
    mgmtd_cfg_db:init(Dir, [{backend, json}]).
