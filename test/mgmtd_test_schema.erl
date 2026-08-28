-module(mgmtd_test_schema).

-export([cfg_schema/0]).

-include("../include/mgmtd.hrl").

cfg_schema() ->
    [#container{name = "interface",
                desc = "Interface configuration",
                config = true,
                children = fun() -> interface_schema() end},
     #container{name = "server",
                desc = "Server configuration",
                config = true,
                children = fun() -> server_list_schema() end},
     #container{name = "client",
                desc = "Client configuration",
                config = true,
                children = fun() -> client_list_schema() end}].

interface_schema() ->
    [#leaf{name = "speed",
           desc = "Interface speed",
           type = {enum, [{"1GbE", "1 Gigabit/s Ethernet"}]},
           default = "1GbE"}].

server_list_schema() ->
    [#list{name = "servers",
           desc = "Server list",
           key_names = ["name"],
           data_callback = mgmtd,
           children = fun() -> server_schema() end}].

server_schema() ->
    [#leaf{name = "name",
           desc = "Server name",
           type = string},
     #leaf{name = "host",
           desc = "Server hostname",
           type = 'inet:ip-address',
           default = "127.0.0.1"},
     #leaf{name = "port",
           desc = "Listen port",
           type = 'inet:port-number',
           default = 80}].

client_list_schema() ->
    [#list{name = "clients",
           desc = "Client list",
           key_names = ["host", "port"],
           children = fun() -> client_schema() end}].

client_schema() ->
    [#leaf{name = "name",
           desc = "Server name",
           type = string},
     #leaf{name = "host",
           desc = "Server hostname",
           type = 'inet:ip-address',
           default = "127.0.0.1"},
     #leaf{name = "port",
           desc = "Server port",
           type = 'inet:port-number',
           default = 8080}].