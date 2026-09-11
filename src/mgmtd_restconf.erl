%%%-------------------------------------------------------------------
%% @doc RESTCONF HTTP listener (RFC 8040).
%%
%% Step one: Cowboy on `restconf_port` (default 8008). Protocol
%% handlers are still stubs.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf).

-export([start/0, stop/0, port/0, default_port/0]).

-define(LISTENER, mgmtd_restconf_http).
-define(DEFAULT_PORT, 8008).

-spec default_port() -> inet:port_number().
default_port() ->
    ?DEFAULT_PORT.

-spec start() -> ok | {error, term()}.
start() ->
    {ok, _} = application:ensure_all_started(cowboy),
    Dispatch = cowboy_router:compile(
                 [{'_', [
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

-spec stop() -> ok.
stop() ->
    case cowboy:stop_listener(?LISTENER) of
        ok ->
            ok;
        {error, not_found} ->
            ok
    end.

-spec port() -> inet:port_number().
port() ->
    ranch:get_port(?LISTENER).

listen_port() ->
    application:get_env(mgmtd, restconf_port, ?DEFAULT_PORT).
