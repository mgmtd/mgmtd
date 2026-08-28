%%%-------------------------------------------------------------------
%%% @author Sean Hinde <sean@Seans-MacBook.local>
%%% @copyright (C) 2019, Sean Hinde
%%% @doc
%%%
%%% Save and read the on disk format of the configuration database.
%%%
%%% The on disk format is based on simple key value .config format key
%%% = value records.
%%%
%%%  ets_to_file should be called in a transaction
%%% context where the ets table will not be modified during the write.
%%%
%%% Multiple complete versions of the database are stored to support
%%% rollback
%%%
%%% @end
%%% Created : 27 Sep 2019 by Sean Hinde <sean@Seans-MacBook.local>
%%%-------------------------------------------------------------------
-module(mgmtd_cfg_db_config).

-export([init/1]).

-export([transaction/1,
         read/2,
         write/2,
         delete/2,
         first/1,
         next/2
        ]).

-export([ets_to_file/1, ets_to_file/2]).
-export([file_to_ets/1, file_to_ets/2]).

-include("mgmtd_schema.hrl").

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
init(Opts) ->
    Dir = proplists:get_value(directory, Opts, "config_db"),
    ok = filelib:ensure_dir(Dir).

transaction(Fun) ->
    %% 0. Somehow lock the disk file
    %% 1. Read the current database to an ets table
    %% 2. Run the operations in Fun against it
    %% 3. Write the table back to ets
    %% 4. unlock the disk file
    ok.

read(Tab, Key) ->
    ok.

write(Tab, Rec) ->
    ok.

delete(Tab, Key) -> ok.


first(Tab) ->
    ok.

next(Tab, Key) ->
    ok.


%%--------------------------------------------------------------------
%% @doc Store the contents of an ets table of #cfg{} records
%% representing a configuration tree to file
%%--------------------------------------------------------------------
-spec ets_to_file(ets:table()) -> ok.
ets_to_file(Ets) ->
    Directory = "store",
    ets_to_file(Ets, Directory).

ets_to_file(Ets, Directory) ->
    ok = filelib:ensure_dir(Directory),
    {ok, Files} = file:list_dir(Directory),
    DbFiles = lists:filter(fun(F) -> lists:prefix("db.",F) end, Files),
    MaxFileNum = max_file_num(DbFiles),
    NewFile = "db." ++ integer_to_list(MaxFileNum + 1),
    NewFilePath = filename:join(Directory, NewFile),
    {ok, Fd} = file:open(NewFilePath, [write, raw]),
    ok = store_ets(Ets, Fd),
    file:close(Fd).

%%--------------------------------------------------------------------
%% @doc Load the contents of the latest ets table of #cfg{} records
%% from a previously saved .config format file.
%%--------------------------------------------------------------------
-spec file_to_ets(ets:table()) -> ok.
file_to_ets(Ets) ->
    Directory = "store",
    file_to_ets(Ets, Directory).

-spec file_to_ets(ets:table(), file:filename()) -> ok.
file_to_ets(Ets, Directory) ->
    {ok, Files} = file:list_dir(Directory),
    DbFiles = lists:filter(fun(F) -> lists:prefix("db.",F) end, Files),
    MaxFileNum = max_file_num(DbFiles),
    File = "db." ++ integer_to_list(MaxFileNum),
    FilePath = filename:join(Directory, File),
    {ok, Fd} = file:open(FilePath, [read, raw, read_ahead]),
    load_ets(Ets, Fd).


%%--------------------------------------------------------------------
%% INTERNAL IMPLEMENTATION
%%--------------------------------------------------------------------
load_ets(Ets, Fd) ->
    %% Loading requires:
    %% 1. Fetching each line, skipping comments / blank lines
    %% 2. Parsing
    %% 3. Validating each line against the schema
    %% 4. Potentially running a migration if the type doesn't match
    %% 5. Skipping anything that doesn't match
    %% 6. inserting to ets
    Line = file:read_line(Fd),
    case parse_line(Line) of
        {ok, Path, Value} ->
            case mgmtd_schema:validate(Path, Value) of
                ok ->
                    ok
            end
    end.

parse_line(Line) ->
    [].

store_ets(Ets, Fd) ->
    ets:foldl(fun store_record/2, Fd, Ets).

store_record(#cfg{} = Cfg, Fd) ->
    Line = cfg_to_config_line(Cfg),
    ok = file:write(Fd, Line),
    Fd.

cfg_to_config_line(#cfg{path = Path, node_type = leaf} = Cfg) ->
    PathL = config_line_path(Path),
    Value = fmt_value(Cfg#cfg.value),
    [PathL, " = ", Value, "\r\n"];
cfg_to_config_line(#cfg{} = _Cfg) ->
    "".

config_line_path(Path) ->
    Elems = [fmt_path_component(P) || P <- Path],
    lists:join($., Elems).

fmt_value(Val) when is_integer(Val) -> integer_to_list(Val);
fmt_value(Float) when is_float(Float) -> float_to_list(Float);
fmt_value(Str) when is_list(Str) -> Str;
fmt_value(Bin) when is_binary(Bin) -> Bin.

fmt_path_component(A) when is_list(A) -> A;
fmt_path_component(T) when is_tuple(T) ->
    L = [fmt_value(V) || V <- tuple_to_list(T)],
    ["{", lists:join($,, L), "}"].

max_file_num([]) -> 0;
max_file_num(DbFiles) ->
    lists:max(lists:map(fun(F) ->
                                list_to_integer(lists:nthtail(3, F))
                        end, DbFiles)).


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

cfgs() ->
    [
     #cfg{path = ["a"], name = "a"},
     #cfg{path = ["a", "b"], name = "b"},
     #cfg{path = ["a", "b", "c"], name = "c", node_type = leaf, value = 100},
     #cfg{path = ["a", "b", "d"], name = "d", node_type = leaf, value = 100.1},
     #cfg{path = ["a", "e"], name = "e", node_type = leaf, value = "E Value"},
     #cfg{path = ["a", "f", {"List","Ke y"}, "key"], name = "e", node_type = leaf, value = "F Value"}
    ].

export_format_test_() ->
    Cfgs = cfgs(),
    Lines = lists:map(fun(Cfg) -> cfg_to_config_line(Cfg) end, Cfgs),
    Output = lists:flatten(Lines),
    Expected =
        "a.b.c = 100\r\n"
        "a.b.d = 1.00099999999999994316e+02\r\n"
        "a.e = E Value\r\n"
        "a.f.{List,Ke y}.key = F Value\r\n",
    ?_assertEqual(Expected, Output).

import_format_test_() ->
    FileContent =
        "a.b.c = 100\r\n"
        "a.b.d = 1.00099999999999994316e+02\r\n"
        "a.e = E Value\r\n"
        "a.f.{List,Ke y}.key = F Value\r\n",
    ?_assertEqual(true, true).

-endif.
