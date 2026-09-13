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
    #{node_type := leaf, type := uint8, default := 1,
      origin_module := "example-remote-aug"} =
        mgmtd_schema:lookup(["base", "root", "y"]),
    #{node_type := leaf, type := string} =
        mgmtd_schema:lookup(["base", "root", "x"]),
    #{origin_module := undefined} =
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

compile_remaining_types_test() ->
    {ok, #{nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-types.yang"),
    #container{name = "types", children = Ch} =
        lists:keyfind("types", #container.name, Nodes),
    Kids = Ch(),
    #leaf{type = {union, [uint8, string]}} =
        lists:keyfind("num-or-name", #leaf.name, Kids),
    #leaf{type = {bits, ["up", "down"]}} =
        lists:keyfind("flags", #leaf.name, Kids),
    #leaf{type = {decimal64, 2, Range}} =
        lists:keyfind("ratio", #leaf.name, Kids),
    ?assertEqual([{min, 0}, {max, 100}], Range),
    #leaf{type = empty} =
        lists:keyfind("marker", #leaf.name, Kids),
    #leaf{type = binary} =
        lists:keyfind("blob", #leaf.name, Kids),
    #leaf{type = {'instance-identifier', true}} =
        lists:keyfind("target", #leaf.name, Kids).

compile_leafref_and_unique_test() ->
    {ok, #{nodes := LrNodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-leafref.yang"),
    #leaf{type = {leafref, "/interface/name", true}} =
        lists:keyfind("outgoing", #leaf.name, LrNodes),
    {ok, #{nodes := UqNodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-unique.yang"),
    #list{opts = Opts} = lists:keyfind("server", #list.name, UqNodes),
    ?assertEqual([["ip", "port"]], proplists:get_value(unique, Opts)).

compile_enum_values_test() ->
    {ok, #{nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-xpath-funs.yang"),
    #leaf{type = {enum, Members}} =
        lists:keyfind("speed", #leaf.name, Nodes),
    ?assertEqual([#{name => "slow", value => 1},
                  #{name => "fast", value => 2}],
                 [maps:with([name, value], M) || M <- Members]).

union_and_bits_cast_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Db = "test_db_yang_types",
    ok = mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-types.yang"),
    ok = mgmtd_cfg_db:init(Db, [{backend, mnesia}]),
    try
        {ok, PInt} = mgmtd_schema:lookup_path(
                       ["ty", "types", "num-or-name", "9"]),
        {ok, Txn} = mgmtd:txn_set(mgmtd:txn_new(), PInt),
        {ok, _} = mgmtd:txn_commit(Txn),
        ?assertEqual({ok, 9}, mgmtd:lookup(["ty", "types", "num-or-name"])),
        {ok, PStr} = mgmtd_schema:lookup_path(
                       ["ty", "types", "num-or-name", "hello"]),
        {ok, Txn2} = mgmtd:txn_set(mgmtd:txn_new(), PStr),
        {ok, _} = mgmtd:txn_commit(Txn2),
        ?assertEqual({ok, "hello"}, mgmtd:lookup(["ty", "types", "num-or-name"])),
        {ok, PBits} = mgmtd_schema:lookup_path(
                        ["ty", "types", "flags", "up down"]),
        {ok, Txn3} = mgmtd:txn_set(mgmtd:txn_new(), PBits),
        {ok, _} = mgmtd:txn_commit(Txn3),
        ?assertEqual({ok, ["up", "down"]},
                     mgmtd:lookup(["ty", "types", "flags"])),
        {ok, PBad} = mgmtd_schema:lookup_path(
                       ["ty", "types", "flags", "nope"]),
        {error, _} = mgmtd:txn_set(mgmtd:txn_new(), PBad),
        {ok, PDec} = mgmtd_schema:lookup_path(
                       ["ty", "types", "ratio", "1.5"]),
        {ok, Txn4} = mgmtd:txn_set(mgmtd:txn_new(), PDec),
        {ok, _} = mgmtd:txn_commit(Txn4),
        ?assertEqual({ok, "1.5"}, mgmtd:lookup(["ty", "types", "ratio"])),
        {ok, PFrac} = mgmtd_schema:lookup_path(
                        ["ty", "types", "ratio", "1.555"]),
        {error, _} = mgmtd:txn_set(mgmtd:txn_new(), PFrac),
        {ok, PMark} = mgmtd_schema:lookup_path(
                        ["ty", "types", "marker", ""]),
        {ok, Txn5} = mgmtd:txn_set(mgmtd:txn_new(), PMark),
        {ok, _} = mgmtd:txn_commit(Txn5),
        ?assertEqual({ok, empty}, mgmtd:lookup(["ty", "types", "marker"])),
        {ok, PBin} = mgmtd_schema:lookup_path(
                       ["ty", "types", "blob", "YWI="]),
        {ok, Txn6} = mgmtd:txn_set(mgmtd:txn_new(), PBin),
        {ok, _} = mgmtd:txn_commit(Txn6),
        ?assertEqual({ok, "YWI="}, mgmtd:lookup(["ty", "types", "blob"]))
    after
        mgmtd:remove_schema(ty),
        mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}])
    end.

leafref_commit_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Db = "test_db_yang_leafref",
    ok = mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-leafref.yang"),
    ok = mgmtd_cfg_db:init(Db, [{backend, mnesia}]),
    try
        Txn = mgmtd:txn_new(),
        {ok, If} = mgmtd_schema:lookup_path(
                     ["lr", "interface", {"eth0"}, "enabled", "true"]),
        {ok, Out} = mgmtd_schema:lookup_path(["lr", "outgoing", "eth0"]),
        {ok, Txn2} = mgmtd:txn_set(Txn, If),
        {ok, Txn3} = mgmtd:txn_set(Txn2, Out),
        {ok, Txn4} = mgmtd:txn_commit(Txn3),
        ?assertEqual({ok, "eth0"}, mgmtd:lookup(["lr", "outgoing"])),
        {ok, Missing} = mgmtd_schema:lookup_path(["lr", "outgoing", "eth1"]),
        {ok, Txn5} = mgmtd:txn_set(Txn4, Missing),
        {error, {leafref_failed, ["lr", "outgoing"], "/interface/name", "eth1"}} =
            mgmtd:txn_commit(Txn5)
    after
        mgmtd:remove_schema(lr),
        mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}])
    end.

leafref_deref_must_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Db = "test_db_yang_deref",
    ok = mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-leafref.yang"),
    ok = mgmtd_cfg_db:init(Db, [{backend, mnesia}]),
    try
        Txn = mgmtd:txn_new(),
        {ok, If} = mgmtd_schema:lookup_path(
                     ["lr", "interface", {"eth0"}, "enabled", "false"]),
        {ok, D} = mgmtd_schema:lookup_path(["lr", "deref-check", "eth0"]),
        {ok, Txn2} = mgmtd:txn_set(Txn, If),
        {ok, Txn3} = mgmtd:txn_set(Txn2, D),
        {error, {must_failed, ["lr", "deref-check"],
                 "deref(current())/../enabled = 'true'",
                 "Outgoing interface must be enabled"}} =
            mgmtd:txn_commit(Txn3),
        {ok, On} = mgmtd_schema:lookup_path(
                     ["lr", "interface", {"eth0"}, "enabled", "true"]),
        {ok, Txn4} = mgmtd:txn_set(mgmtd:txn_new(), On),
        {ok, Txn5} = mgmtd:txn_set(Txn4, D),
        {ok, _} = mgmtd:txn_commit(Txn5)
    after
        mgmtd:remove_schema(lr),
        mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}])
    end.

unique_commit_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Db = "test_db_yang_unique",
    ok = mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-unique.yang"),
    ok = mgmtd_cfg_db:init(Db, [{backend, mnesia}]),
    try
        Txn = mgmtd:txn_new(),
        {ok, A1} = mgmtd_schema:lookup_path(
                     ["uq", "server", {"a"}, "ip", "10.0.0.1"]),
        {ok, A2} = mgmtd_schema:lookup_path(
                     ["uq", "server", {"a"}, "port", "80"]),
        {ok, B1} = mgmtd_schema:lookup_path(
                     ["uq", "server", {"b"}, "ip", "10.0.0.2"]),
        {ok, B2} = mgmtd_schema:lookup_path(
                     ["uq", "server", {"b"}, "port", "80"]),
        {ok, Txn2} = mgmtd:txn_set(Txn, A1),
        {ok, Txn3} = mgmtd:txn_set(Txn2, A2),
        {ok, Txn4} = mgmtd:txn_set(Txn3, B1),
        {ok, Txn5} = mgmtd:txn_set(Txn4, B2),
        {ok, Txn6} = mgmtd:txn_commit(Txn5),
        {ok, C1} = mgmtd_schema:lookup_path(
                     ["uq", "server", {"c"}, "ip", "10.0.0.1"]),
        {ok, C2} = mgmtd_schema:lookup_path(
                     ["uq", "server", {"c"}, "port", "80"]),
        {ok, Txn7} = mgmtd:txn_set(Txn6, C1),
        {ok, Txn8} = mgmtd:txn_set(Txn7, C2),
        {error, {unique_failed, ["uq", "server"], ["ip", "port"]}} =
            mgmtd:txn_commit(Txn8)
    after
        mgmtd:remove_schema(uq),
        mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}])
    end.

instance_identifier_commit_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Db = "test_db_yang_iid",
    ok = mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-types.yang"),
    ok = mgmtd_cfg_db:init(Db, [{backend, mnesia}]),
    try
        {ok, Leaf} = mgmtd_schema:lookup_path(
                       ["ty", "types", "num-or-name", "1"]),
        {ok, Iid} = mgmtd_schema:lookup_path(
                      ["ty", "types", "target", "/types/num-or-name"]),
        {ok, Txn} = mgmtd:txn_set(mgmtd:txn_new(), Leaf),
        {ok, Txn2} = mgmtd:txn_set(Txn, Iid),
        {ok, _} = mgmtd:txn_commit(Txn2),
        {ok, Bad} = mgmtd_schema:lookup_path(
                      ["ty", "types", "target", "/types/missing"]),
        {ok, Txn3} = mgmtd:txn_set(mgmtd:txn_new(), Bad),
        {error, {instance_identifier_failed, ["ty", "types", "target"],
                 "/types/missing"}} =
            mgmtd:txn_commit(Txn3)
    after
        mgmtd:remove_schema(ty),
        mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}])
    end.

xpath_section10_functions_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Db = "test_db_yang_xfun",
    ok = mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-xpath-funs.yang"),
    ok = mgmtd_cfg_db:init(Db, [{backend, mnesia}]),
    try
        {ok, Red} = mgmtd_schema:lookup_path(
                      ["xf", "paint", "colour", "red"]),
        {ok, Txn} = mgmtd:txn_set(mgmtd:txn_new(), Red),
        {ok, _} = mgmtd:txn_commit(Txn),
        {ok, Base} = mgmtd_schema:lookup_path(
                       ["xf", "paint", "not-base", "colour"]),
        {ok, TxnB} = mgmtd:txn_set(mgmtd:txn_new(), Base),
        {error, {must_failed, ["xf", "paint", "not-base"],
                 "derived-from(current(), \"colour\")", undefined}} =
            mgmtd:txn_commit(TxnB),
        {ok, Red2} = mgmtd_schema:lookup_path(
                       ["xf", "paint", "not-base", "red"]),
        {ok, TxnR} = mgmtd:txn_set(mgmtd:txn_new(), Red2),
        {ok, _} = mgmtd:txn_commit(TxnR),
        {ok, Slow} = mgmtd_schema:lookup_path(["xf", "speed", "slow"]),
        {ok, TxnS} = mgmtd:txn_set(mgmtd:txn_new(), Slow),
        {ok, _} = mgmtd:txn_commit(TxnS),
        {ok, Up} = mgmtd_schema:lookup_path(["xf", "flags", "up"]),
        {ok, TxnU} = mgmtd:txn_set(mgmtd:txn_new(), Up),
        {ok, _} = mgmtd:txn_commit(TxnU),
        {ok, Down} = mgmtd_schema:lookup_path(["xf", "flags", "down"]),
        {ok, TxnD} = mgmtd:txn_set(mgmtd:txn_new(), Down),
        {error, {must_failed, ["xf", "flags"],
                 "bit-is-set(current(), \"up\")", undefined}} =
            mgmtd:txn_commit(TxnD),
        {ok, Name} = mgmtd_schema:lookup_path(["xf", "name", "Hello"]),
        {ok, TxnN} = mgmtd:txn_set(mgmtd:txn_new(), Name),
        {ok, _} = mgmtd:txn_commit(TxnN),
        {ok, Bad} = mgmtd_schema:lookup_path(["xf", "name", "hello"]),
        {ok, TxnX} = mgmtd:txn_set(mgmtd:txn_new(), Bad),
        {error, {must_failed, ["xf", "name"],
                 "re-match(current(), \"[A-Z][a-z]+\")", undefined}} =
            mgmtd:txn_commit(TxnX)
    after
        mgmtd:remove_schema(xf),
        mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}])
    end.

compile_cardinality_test() ->
    {ok, #{nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-cardinality.yang"),
    #leaf{name = "hostname", mandatory = true} =
        lists:keyfind("hostname", #leaf.name, Nodes),
    #container{name = "box", children = Box} =
        lists:keyfind("box", #container.name, Nodes),
    Kids = Box(),
    #leaf{name = "name", mandatory = true} =
        lists:keyfind("name", #leaf.name, Kids),
    #container{name = "tagged", children = Tagged} =
        lists:keyfind("tagged", #container.name, Nodes),
    #leaf_list{name = "tags", min_elements = 1, max_elements = 2} =
        lists:keyfind("tags", #leaf_list.name, Tagged()),
    #container{name = "items", children = Items} =
        lists:keyfind("items", #container.name, Nodes),
    #list{name = "item", max_elements = 2, children = Item} =
        lists:keyfind("item", #list.name, Items()),
    #leaf{name = "value", mandatory = true} =
        lists:keyfind("value", #leaf.name, Item()),
    #container{name = "pools", children = Pools} =
        lists:keyfind("pools", #container.name, Nodes),
    #list{name = "pool", min_elements = 1} =
        lists:keyfind("pool", #list.name, Pools()).

cardinality_commit_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Db = "test_db_yang_card",
    ok = mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-cardinality.yang"),
    ok = mgmtd_cfg_db:init(Db, [{backend, mnesia}]),
    try
        {error, {mandatory_failed, ["card", "hostname"]}} =
            mgmtd:txn_commit(mgmtd:txn_new()),
        {ok, _} = commit_paths([["card", "hostname", "box1"]]),
        {ok, PFlag} = mgmtd_schema:lookup_path(["card", "box", "flag", "false"]),
        {ok, TxnFlag} = mgmtd:txn_set(mgmtd:txn_new(), PFlag),
        {error, {mandatory_failed, ["card", "box", "name"]}} =
            mgmtd:txn_commit(TxnFlag),
        {ok, _} = commit_paths([["card", "hostname", "box1"],
                                ["card", "box", "name", "n1"]]),
        {ok, PTrue} = mgmtd_schema:lookup_path(["card", "box", "flag", "true"]),
        {ok, TxnWhen} = mgmtd:txn_set(mgmtd:txn_new(), PTrue),
        {error, {mandatory_failed, ["card", "box", "extra"]}} =
            mgmtd:txn_commit(TxnWhen),
        {ok, _} = commit_paths([["card", "box", "flag", "false"]]),
        {ok, _} = commit_paths([["card", "box", "flag", "true"],
                                ["card", "box", "extra", "e"]]),
        {ok, PKeep} = mgmtd_schema:lookup_path(["card", "tagged", "keep", "true"]),
        {ok, TxnKeep} = mgmtd:txn_set(mgmtd:txn_new(), PKeep),
        {error, {min_elements_failed, ["card", "tagged", "tags"], 1, 0}} =
            mgmtd:txn_commit(TxnKeep),
        {ok, PTags} = mgmtd_schema:lookup_path(
                        ["card", "tagged", "tags", ["a", "b", "c"]]),
        {ok, TxnTags} = mgmtd:txn_set(mgmtd:txn_new(), PTags),
        {error, {max_elements_failed, ["card", "tagged", "tags"], 2, 3}} =
            mgmtd:txn_commit(TxnTags),
        {ok, _} = commit_paths([["card", "tagged", "tags", ["red"]]]),
        {ok, PItem} = mgmtd_schema:lookup_path(["card", "items", "item", {"i1"}]),
        {ok, TxnItem} = mgmtd:txn_set(mgmtd:txn_new(), PItem),
        {error, {mandatory_failed, ["card", "items", "item", {"i1"}, "value"]}} =
            mgmtd:txn_commit(TxnItem),
        {ok, _} = commit_paths([["card", "items", "item", {"i1"}, "value", "v"]]),
        {ok, _} = commit_paths([["card", "items", "item", {"i2"}, "value", "w"]]),
        {ok, PItem3} = mgmtd_schema:lookup_path(
                         ["card", "items", "item", {"i3"}, "value", "x"]),
        {ok, Txn3} = mgmtd:txn_set(mgmtd:txn_new(), PItem3),
        {error, {max_elements_failed, ["card", "items", "item"], 2, 3}} =
            mgmtd:txn_commit(Txn3),
        {ok, PEn} = mgmtd_schema:lookup_path(["card", "pools", "enabled", "true"]),
        {ok, TxnEn} = mgmtd:txn_set(mgmtd:txn_new(), PEn),
        {error, {min_elements_failed, ["card", "pools", "pool"], 1, 0}} =
            mgmtd:txn_commit(TxnEn),
        {ok, _} = commit_paths([["card", "pools", "pool", {"p1"}]]),
        {ok, PSpeed} = mgmtd_schema:lookup_path(
                         ["card", "link", "eth-speed", "1"]),
        {ok, TxnSp} = mgmtd:txn_set(mgmtd:txn_new(), PSpeed),
        {error, {mandatory_failed, ["card", "link", "eth-name"]}} =
            mgmtd:txn_commit(TxnSp),
        {ok, _} = commit_paths([["card", "link", "eth-name", "eth0"]]),
        {ok, PVPI} = mgmtd_schema:lookup_path(["card", "link", "vpi", "8"]),
        {ok, TxnV} = mgmtd:txn_set(mgmtd:txn_new(), PVPI),
        {ok, _} = mgmtd:txn_commit(TxnV)
    after
        mgmtd:remove_schema(card),
        mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}])
    end.

function_cardinality_commit_test() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    Db = "test_db_fun_card",
    ok = mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}]),
    ok = mgmtd:load_function_schema(fun cardinality_fun_schema/0),
    ok = mgmtd_cfg_db:init(Db, [{backend, mnesia}]),
    try
        {ok, _} = mgmtd:txn_commit(mgmtd:txn_new()),
        {ok, PId} = mgmtd_schema:lookup_path(["svc", "id", "a"]),
        {ok, TxnId} = mgmtd:txn_set(mgmtd:txn_new(), PId),
        {error, {min_elements_failed, ["svc", "workers"], 1, 0}} =
            mgmtd:txn_commit(TxnId),
        {ok, PWorker} = mgmtd_schema:lookup_path(["svc", "workers", {"w1"}]),
        {ok, TxnW} = mgmtd:txn_set(mgmtd:txn_new(), PWorker),
        {error, {mandatory_failed, ["svc", "id"]}} =
            mgmtd:txn_commit(TxnW),
        {ok, _} = commit_paths([["svc", "id", "a"],
                                ["svc", "workers", {"w1"}]]),
        {ok, _} = commit_paths([["svc", "workers", {"w2"}]]),
        {ok, P3} = mgmtd_schema:lookup_path(["svc", "workers", {"w3"}]),
        {ok, Txn3} = mgmtd:txn_set(mgmtd:txn_new(), P3),
        {error, {max_elements_failed, ["svc", "workers"], 2, 3}} =
            mgmtd:txn_commit(Txn3)
    after
        mgmtd:remove_schema(),
        mgmtd_cfg_db:remove_db(Db, [{backend, mnesia}])
    end.

cardinality_fun_schema() ->
    [#container{name = "svc",
                config = true,
                children =
                    fun() ->
                            [#leaf{name = "id", type = string, mandatory = true},
                             #list{name = "workers",
                                   key_names = ["name"],
                                   min_elements = 1,
                                   max_elements = 2,
                                   children =
                                       fun() ->
                                               [#leaf{name = "name",
                                                      type = string}]
                                       end}]
                    end}].

commit_paths(Paths) ->
    Txn = lists:foldl(
            fun(Path, Acc) ->
                    {ok, SP} = mgmtd_schema:lookup_path(Path),
                    {ok, Acc1} = mgmtd:txn_set(Acc, SP),
                    Acc1
            end, mgmtd:txn_new(), Paths),
    mgmtd:txn_commit(Txn).

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
