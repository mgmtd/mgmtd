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

uses_inlines_grouping_test() ->
    {ok, #{nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/uses-unsupported.yang"),
    #container{name = "c", children = Ch} =
        lists:keyfind("c", #container.name, Nodes),
    #leaf{name = "x", type = string} =
        lists:keyfind("x", #leaf.name, Ch()).

uses_refine_and_nested_test() ->
    {ok, #{nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-groupings.yang"),
    #container{name = "server", children = Server} =
        lists:keyfind("server", #container.name, Nodes),
    #leaf{name = "port", default = 443, desc = "HTTPS port"} =
        lists:keyfind("port", #leaf.name, Server()),
    #leaf{name = "host", default = "127.0.0.1"} =
        lists:keyfind("host", #leaf.name, Server()),
    #container{name = "proxy", children = Proxy} =
        lists:keyfind("proxy", #container.name, Nodes),
    #container{name = "inner", children = Inner} =
        lists:keyfind("inner", #container.name, Proxy()),
    #leaf{name = "port", default = 80} =
        lists:keyfind("port", #leaf.name, Inner()).

import_ietf_types_test() ->
    {ok, #{prefix := imp, nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-import.yang"),
    #container{name = "net", children = Net} =
        lists:keyfind("net", #container.name, Nodes),
    #leaf{name = "port", type = 'inet:port-number', default = 80} =
        lists:keyfind("port", #leaf.name, Net()),
    #leaf{name = "addr", type = 'inet:ip-address'} =
        lists:keyfind("addr", #leaf.name, Net()),
    #leaf{name = "ticks", type = uint32} =
        lists:keyfind("ticks", #leaf.name, Net()),
    #leaf{name = "mac", type = string} =
        lists:keyfind("mac", #leaf.name, Net()).

compile_ietf_yang_types_no_data_nodes_test() ->
    {ok, #{module := "ietf-yang-types", prefix := yang, nodes := []}} =
        mgmtd_schema_yang:compile_file("priv/yang/ietf-yang-types.yang").

imported_grouping_test() ->
    {ok, #{nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-uses-import.yang"),
    #list{name = "items", key_names = ["name"], children = Ch} =
        lists:keyfind("items", #list.name, Nodes),
    #leaf{name = "name", type = string} =
        lists:keyfind("name", #leaf.name, Ch()),
    #leaf{name = "value", type = string} =
        lists:keyfind("value", #leaf.name, Ch()).

include_submodule_test() ->
    {ok, #{nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-parent.yang"),
    Names = lists:sort([name(N) || N <- Nodes]),
    ?assertEqual(["extra", "top"], Names),
    #container{children = Extra} =
        lists:keyfind("extra", #container.name, Nodes),
    #leaf{name = "from-sub", type = uint8} =
        lists:keyfind("from-sub", #leaf.name, Extra()).

if_feature_default_keeps_all_test() ->
    {ok, #{nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-features.yang"),
    Leaves = leaf_names(root_children(Nodes)),
    ?assertEqual(["always", "both", "fancy-leaf", "not-fancy"], lists:sort(Leaves)).

if_feature_none_drops_guarded_test() ->
    {ok, #{nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-features.yang",
                                       #{features => none}),
    Leaves = leaf_names(root_children(Nodes)),
    ?assertEqual(["always", "not-fancy"], lists:sort(Leaves)).

if_feature_named_test() ->
    {ok, #{nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-features.yang",
                                       #{features => [fancy]}),
    Leaves = leaf_names(root_children(Nodes)),
    ?assertEqual(["always", "fancy-leaf"], lists:sort(Leaves)).

circular_uses_test() ->
    {error, {_Ln, circular_uses, _}} =
        mgmtd_schema_yang:compile_file("test/yang/example-circular-uses.yang").

missing_import_test() ->
    Yang = <<"
        module m {
          namespace \"urn:m\";
          prefix m;
          import no-such-module { prefix x; }
          leaf n { type string; }
        }
    ">>,
    {ok, Stmts} = mgmtd_yang_parse:string(Yang),
    {error, {_Ln, "no-such-module", {module_not_found, "no-such-module"}}} =
        mgmtd_schema_yang:compile(Stmts).

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

choice_flatten_test() ->
    {ok, #{nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-choice.yang"),
    #container{name = "link", children = Link} =
        lists:keyfind("link", #container.name, Nodes),
    Children = Link(),
    Names = lists:sort(leaf_names(Children)),
    ?assertEqual(["eth-name", "other", "vpi"], Names),
    #leaf{opts = EthOpts} = lists:keyfind("eth-name", #leaf.name, Children),
    ?assertEqual("type", proplists:get_value(choice, EthOpts)),
    ?assertEqual("ethernet", proplists:get_value('case', EthOpts)),
    ?assertEqual("ethernet", proplists:get_value(choice_default, EthOpts)),
    #leaf{opts = OtherOpts} = lists:keyfind("other", #leaf.name, Children),
    ?assertEqual("other", proplists:get_value('case', OtherOpts)).

identity_compile_test() ->
    {ok, #{identities := Ids, nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-identity.yang"),
    Locals = lists:sort([binary_to_list(maps:get(local, I)) || I <- Ids]),
    ?assertEqual(["blue", "car", "colour", "red"], Locals),
    #container{children = Paint} =
        lists:keyfind("paint", #container.name, Nodes),
    #leaf{type = {identityref, Base}} =
        lists:keyfind("colour", #leaf.name, Paint()),
    ?assertEqual("example-identity:colour", Base).

local_augment_test() ->
    {ok, #{nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-augment-local.yang"),
    #container{children = Ifs} =
        lists:keyfind("interfaces", #container.name, Nodes),
    #list{children = Item} =
        lists:keyfind("interface", #list.name, Ifs()),
    Names = lists:sort([name(N) || N <- Item()]),
    ?assertEqual(["enabled", "name"], Names),
    #leaf{name = "enabled", type = boolean, default = true} =
        lists:keyfind("enabled", #leaf.name, Item()).

uses_augment_test() ->
    {ok, #{nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-uses-augment.yang"),
    #container{children = C} =
        lists:keyfind("c", #container.name, Nodes),
    #container{name = "target", children = T} =
        lists:keyfind("target", #container.name, C()),
    Names = lists:sort(leaf_names(T())),
    ?assertEqual(["a", "b"], Names).

remote_augment_load_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd:load_yang_module("test/yang/example-base.yang"),
    ok = mgmtd:load_yang_module("test/yang/example-remote-aug.yang"),
    #{node_type := leaf, type := uint8, default := 1} =
        mgmtd_schema:lookup(["base", "root", "y"]),
    #{node_type := leaf, type := string} =
        mgmtd_schema:lookup(["base", "root", "x"]),
    ok = mgmtd:remove_schema(base),
    ok = mgmtd:remove_schema(ra).

identityref_cast_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Db = "test_db_yang_id",
    ok = mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-identity.yang"),
    ok = mgmtd_cfg_db:init(Db, [{backend, mnesia}]),
    try
        {ok, Path} = mgmtd_schema:lookup_path(
                       ["idn", "paint", "colour", "red"]),
        {ok, Txn} = mgmtd:txn_set(mgmtd:txn_new(), Path),
        {ok, _} = mgmtd:txn_commit(Txn),
        ?assertEqual({ok, "red"}, mgmtd:lookup(["idn", "paint", "colour"])),
        {ok, Path2} = mgmtd_schema:lookup_path(
                        ["idn", "paint", "colour", "car"]),
        {error, _} = mgmtd:txn_set(mgmtd:txn_new(), Path2)
    after
        mgmtd:remove_schema(idn),
        mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}])
    end.

must_true_commit_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Db = "test_db_yang_must",
    ok = mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-must.yang"),
    ok = mgmtd_cfg_db:init(Db, [{backend, mnesia}]),
    try
        Txn = mgmtd:txn_new(),
        {ok, P1} = mgmtd_schema:lookup_path(["m", "box", "flag", "true"]),
        {ok, Txn2} = mgmtd:txn_set(Txn, P1),
        {ok, _} = mgmtd:txn_commit(Txn2)
    after
        mgmtd:remove_schema(m),
        mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}])
    end.

when_false_rejects_commit_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Db = "test_db_yang_when",
    ok = mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-must.yang"),
    ok = mgmtd_cfg_db:init(Db, [{backend, mnesia}]),
    try
        Txn = mgmtd:txn_new(),
        {ok, P1} = mgmtd_schema:lookup_path(["m", "box", "extra", "nope"]),
        {ok, Txn2} = mgmtd:txn_set(Txn, P1),
        {error, {when_failed, ["m", "box", "extra"], "../flag = 'true'"}} =
            mgmtd:txn_commit(Txn2)
    after
        mgmtd:remove_schema(m),
        mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}])
    end.

when_true_allows_commit_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Db = "test_db_yang_when_ok",
    ok = mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-must.yang"),
    ok = mgmtd_cfg_db:init(Db, [{backend, mnesia}]),
    try
        Txn = mgmtd:txn_new(),
        {ok, Pf} = mgmtd_schema:lookup_path(["m", "box", "flag", "true"]),
        {ok, Pe} = mgmtd_schema:lookup_path(["m", "box", "extra", "ok"]),
        {ok, Txn2} = mgmtd:txn_set(Txn, Pf),
        {ok, Txn3} = mgmtd:txn_set(Txn2, Pe),
        {ok, _} = mgmtd:txn_commit(Txn3)
    after
        mgmtd:remove_schema(m),
        mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}])
    end.

must_false_rejects_commit_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Db = "test_db_yang_must_fail",
    ok = mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-must.yang"),
    ok = mgmtd_cfg_db:init(Db, [{backend, mnesia}]),
    try
        Txn = mgmtd:txn_new(),
        {ok, Pf} = mgmtd_schema:lookup_path(["m", "box", "flag", "false"]),
        {ok, Pg} = mgmtd_schema:lookup_path(["m", "box", "gated", "x"]),
        {ok, Txn2} = mgmtd:txn_set(Txn, Pf),
        {ok, Txn3} = mgmtd:txn_set(Txn2, Pg),
        {error, {must_failed, ["m", "box", "gated"], "../flag = 'true'",
                 "flag must be true"}} =
            mgmtd:txn_commit(Txn3)
    after
        mgmtd:remove_schema(m),
        mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}])
    end.

must_current_outgoing_interface_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Db = "test_db_yang_current",
    ok = mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-must.yang"),
    ok = mgmtd_cfg_db:init(Db, [{backend, mnesia}]),
    try
        Txn = mgmtd:txn_new(),
        {ok, N0} = mgmtd_schema:lookup_path(
                     ["m", "interface", {"eth0"}, "enabled", "true"]),
        {ok, N1} = mgmtd_schema:lookup_path(
                     ["m", "interface", {"eth1"}, "outgoing-interface", "eth0"]),
        {ok, Txn2} = mgmtd:txn_set(Txn, N0),
        {ok, Txn3} = mgmtd:txn_set(Txn2, N1),
        {ok, Txn4} = mgmtd:txn_commit(Txn3),
        {ok, Off} = mgmtd_schema:lookup_path(
                      ["m", "interface", {"eth0"}, "enabled", "false"]),
        {ok, Txn5} = mgmtd:txn_set(Txn4, Off),
        {error, {must_failed, ["m", "interface", {"eth1"}, "outgoing-interface"],
                 "/interface[name=current()]/enabled = 'true'",
                 "Outgoing interface must be enabled"}} =
            mgmtd:txn_commit(Txn5)
    after
        mgmtd:remove_schema(m),
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

root_children(Nodes) ->
    #container{children = Ch} = lists:keyfind("root", #container.name, Nodes),
    Ch().

leaf_names(Children) ->
    [N || #leaf{name = N} <- Children].
