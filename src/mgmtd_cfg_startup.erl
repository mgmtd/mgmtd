%%%-------------------------------------------------------------------
%%% @doc Startup store — factory config loaded once into the main store.
%%%
%%% The startup store is configured independently of the running
%%% (main) database. It is read only when the main store does not yet
%%% exist; after a successful load the main store is created with that
%%% content and later starts ignore the startup file.
%%%
%%% First version: a single `sys.config` file.
%%%
%%%     {startup, [{backend, sys_config}, {file, "config/factory.config"}]}
%%%
%%% Pass `{startup, Opts}` to `mgmtd_cfg_db:init/2`, or set application
%%% env `startup`. `{startup, []}` / `{startup, false}` disables it.
%%% The file is never written back.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_cfg_startup).

-export([maybe_load/2]).

-spec maybe_load(new | existing, proplists:proplist()) -> ok | {error, term()}.
maybe_load(existing, _Opts) ->
    ok;
maybe_load(new, Opts) ->
    case startup_opts(Opts) of
        undefined ->
            ok;
        StartupOpts ->
            load_and_apply(StartupOpts)
    end.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

startup_opts(Opts) ->
    case proplists:get_value(startup, Opts, undefined) of
        undefined ->
            env_startup();
        false ->
            undefined;
        [] ->
            undefined;
        Props when is_list(Props) ->
            Props;
        _Other ->
            undefined
    end.

env_startup() ->
    case application:get_env(mgmtd, startup, undefined) of
        undefined ->
            undefined;
        false ->
            undefined;
        [] ->
            undefined;
        Props when is_list(Props) ->
            Props;
        _Other ->
            undefined
    end.

load_and_apply(StartupOpts) ->
    case load_rows(StartupOpts) of
        {ok, Rows} ->
            apply_rows(Rows);
        {error, _} = Err ->
            Err
    end.

load_rows(Opts) ->
    Backend = proplists:get_value(backend, Opts, sys_config),
    case Backend of
        sys_config ->
            case startup_file(Opts) of
                undefined ->
                    {error, {invalid_startup, no_file}};
                File ->
                    mgmtd_cfg_db_sys_config:load_file(File)
            end;
        Other ->
            {error, {unsupported_startup_backend, Other}}
    end.

startup_file(Opts) ->
    case proplists:get_value(file, Opts, undefined) of
        File when is_list(File); is_binary(File) ->
            File;
        undefined ->
            case proplists:get_value(location, Opts, undefined) of
                Dir when is_list(Dir); is_binary(Dir) ->
                    filename:join(Dir, "sys.config");
                _ ->
                    undefined
            end;
        _ ->
            undefined
    end.

apply_rows(Rows) when is_list(Rows) ->
    mgmtd_cfg_db:transaction(fun() ->
                                     mgmtd_cfg_db:replace_all(Rows)
                             end).
