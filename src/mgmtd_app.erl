%%%-------------------------------------------------------------------
%% @doc mgmtd public API
%% @end
%%%-------------------------------------------------------------------

-module(mgmtd_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case mgmtd_sup:start_link() of
        {ok, Pid} ->
            case mgmtd_restconf:start() of
                ok ->
                    {ok, Pid};
                {error, Reason} ->
                    exit(Pid, shutdown),
                    {error, Reason}
            end;
        Other ->
            Other
    end.

stop(_State) ->
    mgmtd_restconf:stop(),
    ok.

%% internal functions
