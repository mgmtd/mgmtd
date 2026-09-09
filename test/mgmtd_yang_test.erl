-module(mgmtd_yang_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/mgmtd.hrl").

scan_comments_and_concat_test() ->
    Text = <<"module m { namespace \"urn:x\" + \"x\"; prefix m; }">>,
    {ok, Scan} = mgmtd_yang_scan:string(Text),
    {ok, Tokens} = mgmtd_yang_scan:all(Scan),
    ?assertMatch([{word, 1, <<"module">>},
                  {word, 1, <<"m">>},
                  {'{', 1},
                  {word, 1, <<"namespace">>},
                  {string, 1, <<"urn:xx">>} | _],
                 Tokens).

scan_line_comment_test() ->
    {ok, Scan} = mgmtd_yang_scan:string(<<"foo // comment\nbar">>),
    {ok, Tokens} = mgmtd_yang_scan:all(Scan),
    ?assertEqual([{word, 1, <<"foo">>}, {word, 2, <<"bar">>}], Tokens).

parse_minimal_module_test() ->
    Yang = <<"
        module example {
          namespace \"urn:example\";
          prefix ex;
          container box {
            leaf n {
              type uint8;
            }
          }
        }
    ">>,
    {ok, [{module, _, <<"example">>, Body}]} = mgmtd_yang_parse:string(Yang),
    ?assertEqual(<<"urn:example">>, stmt_arg(namespace, Body)),
    ?assertEqual(<<"ex">>, stmt_arg(prefix, Body)),
    {container, _, <<"box">>, CBody} = lists:keyfind(container, 1, Body),
    {leaf, _, <<"n">>, LBody} = lists:keyfind(leaf, 1, CBody),
    {type, _, <<"uint8">>, []} = lists:keyfind(type, 1, LBody).

compile_example_server_test() ->
    {ok, #{module := "example-server",
           prefix := ex,
           namespace := "urn:example:server",
           nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-server.yang"),
    Names = [name(N) || N <- Nodes],
    ?assertEqual(["interface", "server", "client"], Names),
    #container{config = true, children = IF} =
        lists:keyfind("interface", #container.name, Nodes),
    #leaf{name = "speed", type = {enum, [#{name := "1GbE"}]},
          default = "1GbE"} =
        lists:keyfind("speed", #leaf.name, IF()),
    #leaf{name = "load", type = {uint8, Range}, default = 0} =
        lists:keyfind("load", #leaf.name, IF()),
    ?assertEqual([{min, 0}, {max, 100}], Range),
    #container{children = Server} =
        lists:keyfind("server", #container.name, Nodes),
    #list{name = "servers", key_names = ["name"], children = Items} =
        lists:keyfind("servers", #list.name, Server()),
    #leaf{name = "port", type = 'inet:port-number', default = 80} =
        lists:keyfind("port", #leaf.name, Items()),
    #container{children = Client} =
        lists:keyfind("client", #container.name, Nodes),
    #list{key_names = ["host", "port"]} =
        lists:keyfind("clients", #list.name, Client()).

uses_is_rejected_test() ->
    {error, {_Ln, unsupported_statement, uses, "g"}} =
        mgmtd_schema_yang:compile_file("test/yang/uses-unsupported.yang").

load_yang_module_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd:load_yang_module("test/yang/example-server.yang"),
    ?assert(lists:member(ex, mgmtd:registered_schemas())),
    #{ns := ex, node_type := container, path := ["ex"]} =
        mgmtd_schema:lookup(["ex"]),
    #{node_type := list, key_names := ["name"], ns := ex} =
        mgmtd_schema:lookup(["ex", "server", "servers"]),
    #{type := {enum, [#{name := "1GbE"}]}, default := "1GbE"} =
        mgmtd_schema:lookup(["ex", "interface", "speed"]),
    #{type := {uint8, [{min, 0}, {max, 100}]}, default := 0} =
        mgmtd_schema:lookup(["ex", "interface", "load"]),
    #{type := 'inet:port-number', default := 80} =
        mgmtd_schema:lookup(["ex", "server", "servers", "port"]),
    #{type := 'inet:ip-address', default := "127.0.0.1"} =
        mgmtd_schema:lookup(["ex", "client", "clients", "host"]),
    ok = mgmtd:remove_schema(ex).

load_yang_with_default_prefix_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd:load_yang_module("test/yang/example-server.yang",
                                #{prefix => default}),
    #{node_type := list, key_names := ["name"], ns := default} =
        mgmtd_schema:lookup(["server", "servers"]),
    #{type := 'inet:port-number'} =
        mgmtd_schema:lookup(["server", "servers", "port"]),
    ok = mgmtd:remove_schema().

yang_txn_set_commit_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Db = "test_db_yang",
    ok = mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-server.yang"),
    ok = mgmtd_cfg_db:init(Db, [{backend, mnesia}]),
    try
        {ok, Path} = mgmtd_schema:lookup_path(
                       ["ex", "server", "servers", {"s1"}, "port", "8080"]),
        {ok, Txn} = mgmtd:txn_set(mgmtd:txn_new(), Path),
        {ok, _} = mgmtd:txn_commit(Txn),
        ?assertEqual({ok, 8080},
                     mgmtd:lookup(["ex", "server", "servers", {"s1"}, "port"]))
    after
        mgmtd:remove_schema(ex),
        mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}])
    end.

must_and_when_stored_on_opts_test() ->
    Yang = <<"
        module m {
          namespace \"urn:m\";
          prefix m;
          container c {
            must \"1 = 1\" {
              error-message \"nope\";
            }
            leaf x {
              type boolean;
              when \"../x = true\";
            }
          }
        }
    ">>,
    {ok, Stmts} = mgmtd_yang_parse:string(Yang),
    {ok, #{nodes := [#container{opts = COpts, children = Ch}]}} =
        mgmtd_schema_yang:compile(Stmts),
    ?assertMatch([{must, #{expr := "1 = 1", error_message := "nope"}}], COpts),
    #leaf{opts = LOpts} = lists:keyfind("x", #leaf.name, Ch()),
    ?assertEqual([{'when', "../x = true"}], LOpts).

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

stmt_arg(Key, Body) ->
    {Key, _, Arg, _} = lists:keyfind(Key, 1, Body),
    Arg.

name(#container{name = N}) -> N;
name(#list{name = N}) -> N;
name(#leaf{name = N}) -> N;
name(#leaf_list{name = N}) -> N.
