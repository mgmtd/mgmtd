%%%-------------------------------------------------------------------
%%% @doc Test-only operational-data provider.
%%%
%%% Serves a small `status` tree from hardcoded values. Application
%%% providers live with the host schema, not in this library.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_test_provider).

-behaviour(mgmtd_provider).

-export([get_value/1, get_first/1, get_next/2, list_keys/3, schema/0]).

-include("../include/mgmtd.hrl").

schema() ->
    [#container{name = "status",
                desc = "Operational status",
                config = false,
                data_callback = ?MODULE,
                children = fun status_schema/0},
     #container{name = "orphan",
                desc = "Operational tree with no provider",
                config = false,
                children = fun orphan_schema/0}].

status_schema() ->
    [#leaf{name = "uptime",
           desc = "Time since boot",
           type = string},
     #leaf_list{name = "tags",
                desc = "Status tags",
                type = string},
     #list{name = "interfaces",
           desc = "Interface status",
           key_names = ["name"],
           children = fun iface_schema/0},
     #list{name = "peers",
           desc = "Peers by host and port",
           key_names = ["host", "port"],
           children = fun peer_schema/0}].

iface_schema() ->
    [#leaf{name = "name", desc = "Interface name", type = string},
     #leaf{name = "state", desc = "Link state",
           type = {enum, ["up", "down"]}},
     #leaf{name = "mtu", desc = "MTU", type = uint32}].

peer_schema() ->
    [#leaf{name = "host", desc = "Peer address", type = 'inet:ip-address'},
     #leaf{name = "port", desc = "Peer port", type = 'inet:port-number'},
     #leaf{name = "state", desc = "Session state", type = string}].

orphan_schema() ->
    [#leaf{name = "n", desc = "Unbacked leaf", type = int32}].

%%--------------------------------------------------------------------
get_value(["status", "uptime"]) ->
    {ok, "1d4h"};
get_value(["status", "tags"]) ->
    {ok, ["core", "edge"]};
get_value(["status", "interfaces", {"eth0"}, "state"]) ->
    {ok, "up"};
get_value(["status", "interfaces", {"eth0"}, "mtu"]) ->
    {ok, 1500};
get_value(["status", "interfaces", {"eth1"}, "state"]) ->
    {ok, "down"};
get_value(["status", "interfaces", {"eth1"}, "mtu"]) ->
    {ok, 1500};
get_value(["status", "peers", {{127,0,0,1}, 8080}, "state"]) ->
    {ok, "established"};
get_value(["jsonoper", "uptime"]) ->
    {ok, "9s"};
get_value(_Path) ->
    {ok, not_found}.

get_first(["status", "interfaces"]) ->
    {ok, {"eth0"}};
get_first(["status", "peers"]) ->
    {ok, {{127,0,0,1}, 8080}};
get_first(_Path) ->
    {ok, not_found}.

get_next(["status", "interfaces"], {"eth0"}) ->
    {ok, {"eth1"}};
get_next(_Path, _Prev) ->
    {ok, not_found}.

list_keys(_Txn, Path, Match) ->
    case mgmtd_provider:list_keys(?MODULE, Path, Match) of
        {ok, Keys} ->
            Keys;
        {error, _} ->
            []
    end.
