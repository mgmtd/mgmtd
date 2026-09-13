%%%-------------------------------------------------------------------
%% @doc RESTCONF HTTP listener (RFC 8040).
%%
%% sys.config (`mgmtd`):
%%
%%     {restconf, [{enabled, true}, {port, 8008}]}
%%
%% `enabled` defaults to true. `{restconf, false}` leaves the HTTP
%% listener off; `{restconf, true}` is the default port.
%%
%% Schema snapshot for clients is `GET /mgmtd/schema` (not RESTCONF).
%% HTML UI is not served here: hosts mount `mgmtd_ui:cowboy_routes/0`
%% on their own Cowboy listener.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf).

-export([start/0, stop/0, port/0, default_port/0, enabled/0]).

-define(LISTENER, mgmtd_restconf_http).
-define(DEFAULT_PORT, 8008).

-spec default_port() -> inet:port_number().
default_port() ->
    ?DEFAULT_PORT.

-spec enabled() -> boolean().
enabled() ->
    proplists:get_value(enabled, config(), true).

-spec start() -> ok | {error, term()}.
start() ->
    case enabled() of
        false ->
            ok;
        true ->
            start_listener()
    end.

-spec stop() -> ok.
stop() ->
    try cowboy:stop_listener(?LISTENER) of
        ok ->
            ok;
        {error, not_found} ->
            ok
    catch
        _:_ ->
            ok
    end.

-spec port() -> inet:port_number().
port() ->
    ranch:get_port(?LISTENER).

start_listener() ->
    {ok, _} = application:ensure_all_started(cowboy),
    Dispatch = cowboy_router:compile(
                 [{'_', [
                         {"/mgmtd/schema", mgmtd_ui_schema_handler, []},
                         {"/mgmtd/schema/", mgmtd_ui_schema_handler, []},
                         {"/.well-known/host-meta", mgmtd_restconf_handler, []},
                         {"/restconf/[...]", mgmtd_restconf_handler, []}
                        ]}]),
    TransOpts = [{port, listen_port()}],
    ProtoOpts = #{env => #{dispatch => Dispatch}},
    case cowboy:start_clear(?LISTENER, TransOpts, ProtoOpts) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

listen_port() ->
    proplists:get_value(port, config(), ?DEFAULT_PORT).

config() ->
    case application:get_env(mgmtd, restconf, []) of
        true ->
            [{enabled, true}];
        false ->
            [{enabled, false}];
        List when is_list(List) ->
            List
    end.
