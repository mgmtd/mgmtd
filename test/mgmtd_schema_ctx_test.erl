%%%-------------------------------------------------------------------
%%% Isolated schema contexts and load from YANG binary.
%%%-------------------------------------------------------------------
-module(mgmtd_schema_ctx_test).

-include_lib("eunit/include/eunit.hrl").

-define(YANG_A,
        <<"module iso-a {\n"
          "  namespace \"urn:iso:a\";\n"
          "  prefix a;\n"
          "  container only-a {\n"
          "    leaf x { type string; }\n"
          "  }\n"
          "}\n">>).
-define(YANG_B,
        <<"module iso-b {\n"
          "  namespace \"urn:iso:b\";\n"
          "  prefix b;\n"
          "  container only-b {\n"
          "    leaf y { type uint8; }\n"
          "  }\n"
          "}\n">>).
-define(YANG_IMP,
        <<"module iso-types {\n"
          "  namespace \"urn:iso:types\";\n"
          "  prefix t;\n"
          "  typedef tag { type string; }\n"
          "}\n">>).
-define(YANG_USES,
        <<"module iso-use {\n"
          "  namespace \"urn:iso:use\";\n"
          "  prefix u;\n"
          "  import iso-types { prefix t; }\n"
          "  container box {\n"
          "    leaf tag { type t:tag; }\n"
          "  }\n"
          "}\n">>).

ctx_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun binary_load_global/0,
      fun two_contexts_isolated/0,
      fun snapshot_isolated/0,
      fun in_memory_import/0]}.

setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok.

teardown(_) ->
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

binary_load_global() ->
    {ok, File} = file:read_file("test/yang/example-server.yang"),
    ?assertEqual(ok, mgmtd:load_yang_module_binary(File)),
    #{node_type := list, key_names := ["name"]} =
        mgmtd_schema:lookup(["ex", "server", "servers"]),
    ok = mgmtd:remove_schema(ex).

two_contexts_isolated() ->
    A = mgmtd_schema:new_ctx(),
    B = mgmtd_schema:new_ctx(),
    try
        ?assertEqual(ok, mgmtd_schema:with_ctx(
                           A, fun() -> mgmtd:load_yang_module_binary(?YANG_A) end)),
        ?assertEqual(ok, mgmtd_schema:with_ctx(
                           B, fun() -> mgmtd:load_yang_module_binary(?YANG_B) end)),
        mgmtd_schema:with_ctx(
          A,
          fun() ->
                  ?assertMatch(#{node_type := container},
                               mgmtd_schema:lookup(["a", "only-a"])),
                  ?assertEqual(false, mgmtd_schema:lookup(["b", "only-b"]))
          end),
        mgmtd_schema:with_ctx(
          B,
          fun() ->
                  ?assertMatch(#{node_type := container},
                               mgmtd_schema:lookup(["b", "only-b"])),
                  ?assertEqual(false, mgmtd_schema:lookup(["a", "only-a"]))
          end),
        ?assertEqual(false, mgmtd_schema:lookup(["a", "only-a"])),
        ?assertEqual(false, mgmtd_schema:lookup(["b", "only-b"]))
    after
        mgmtd_schema:destroy_ctx(A),
        mgmtd_schema:destroy_ctx(B)
    end.

snapshot_isolated() ->
    A = mgmtd_schema:new_ctx(),
    B = mgmtd_schema:new_ctx(),
    try
        ok = mgmtd_schema:with_ctx(A, fun() -> mgmtd:load_yang_module_binary(?YANG_A) end),
        ok = mgmtd_schema:with_ctx(B, fun() -> mgmtd:load_yang_module_binary(?YANG_B) end),
        SnapA = mgmtd_schema:with_ctx(A, fun mgmtd_ui_schema:snapshot/0),
        SnapB = mgmtd_schema:with_ctx(B, fun mgmtd_ui_schema:snapshot/0),
        NamesA = [maps:get(<<"name">>, M) || M <- maps:get(<<"modules">>, SnapA)],
        NamesB = [maps:get(<<"name">>, M) || M <- maps:get(<<"modules">>, SnapB)],
        ?assertEqual([<<"iso-a">>], NamesA),
        ?assertEqual([<<"iso-b">>], NamesB),
        [ModA] = maps:get(<<"modules">>, SnapA),
        ChildNames = [maps:get(<<"name">>, C) || C <- maps:get(<<"children">>, ModA)],
        ?assertEqual([<<"only-a">>], ChildNames)
    after
        mgmtd_schema:destroy_ctx(A),
        mgmtd_schema:destroy_ctx(B)
    end.

in_memory_import() ->
    Ctx = mgmtd_schema:new_ctx(),
    try
        Opts = #{yang_modules => #{<<"iso-types">> => ?YANG_IMP,
                                   "iso-types" => ?YANG_IMP}},
        ?assertEqual(
           ok,
           mgmtd_schema:with_ctx(
             Ctx,
             fun() -> mgmtd:load_yang_module_binary(?YANG_USES, Opts) end)),
        mgmtd_schema:with_ctx(
          Ctx,
          fun() ->
                  #{node_type := leaf} =
                      mgmtd_schema:lookup(["u", "box", "tag"])
          end)
    after
        mgmtd_schema:destroy_ctx(Ctx)
    end.
