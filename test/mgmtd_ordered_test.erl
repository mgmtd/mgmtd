%%%-------------------------------------------------------------------
%%% @doc ordered-by user lists and leaf-lists.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_ordered_test).

-include_lib("eunit/include/eunit.hrl").
-include("../include/mgmtd.hrl").

-define(DB, "test_db_ordered").

compile_test() ->
    {ok, #{nodes := Nodes}} =
        mgmtd_schema_yang:compile_file("test/yang/example-ordered.yang"),
    #container{name = "acl", children = Acl} =
        lists:keyfind("acl", #container.name, Nodes),
    Kids = Acl(),
    #list{name = "rule", ordered_by = user} =
        lists:keyfind("rule", #list.name, Kids),
    #leaf_list{name = "tag", ordered_by = user} =
        lists:keyfind("tag", #leaf_list.name, Kids),
    #container{name = "sys", children = Sys} =
        lists:keyfind("sys", #container.name, Nodes),
    #list{name = "item", ordered_by = system} =
        lists:keyfind("item", #list.name, Sys()).

runtime_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun set_appends_in_user_order/0,
      fun move_first_last_before_after/0,
      fun delete_removes_from_order/0,
      fun show_and_lookup_preserve_order/0,
      fun restconf_get_array_order/0,
      fun restconf_post_insert/0,
      fun restconf_put_move/0,
      fun insert_rejected_on_system_list/0,
      fun leaf_list_order_and_move/0,
      fun function_schema_ordered_by/0,
      fun move_unknown_point/0,
      fun list_keys_match_follows_user_order/0]}.

setup() ->
    start_mgmtd(),
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB, [{backend, mnesia}]),
    ok = mgmtd:load_yang_module("test/yang/example-ordered.yang"),
    ok = mgmtd_cfg_db:init(?DB, [{backend, mnesia}]),
    Prev = application:get_env(mgmtd, restconf),
    ok = application:set_env(mgmtd, restconf, [{enabled, true}, {port, 0}]),
    ok = mgmtd_restconf:start(),
    {ok, _} = application:ensure_all_started(inets),
    Prev.

teardown(Prev) ->
    ok = mgmtd_restconf:stop(),
    case Prev of
        undefined -> application:unset_env(mgmtd, restconf);
        {ok, Val} -> application:set_env(mgmtd, restconf, Val)
    end,
    lists:foreach(fun mgmtd:remove_schema/1, mgmtd:registered_schemas()),
    ok = mgmtd_cfg_db:remove_db(?DB, [{backend, mnesia}]),
    ok.

start_mgmtd() ->
    case mgmtd_sup:start_link() of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end.

set_appends_in_user_order() ->
    {ok, _} = commit_paths([["ord", "acl", "rule", {"z"}, "action", "drop"],
                            ["ord", "acl", "rule", {"a"}, "action", "permit"],
                            ["ord", "acl", "rule", {"m"}, "action", "drop"]]),
    ?assertEqual([{"z"}, {"a"}, {"m"}],
                 mgmtd_cfg_db:list_keys(["ord", "acl", "rule"])),
    {ok, Keys} = mgmtd:lookup(["ord", "acl", "rule"]),
    ?assertEqual([{"z"}, {"a"}, {"m"}], [K || K <- Keys, is_tuple(K)]),
    clear_rules().

move_first_last_before_after() ->
    {ok, _} = commit_paths([["ord", "acl", "rule", {"z"}, "action", "drop"],
                            ["ord", "acl", "rule", {"a"}, "action", "permit"],
                            ["ord", "acl", "rule", {"m"}, "action", "drop"]]),
    Txn = mgmtd:txn_new(),
    {ok, SP} = mgmtd_schema:lookup_path(["ord", "acl", "rule", {"a"}]),
    {ok, Txn2} = mgmtd:txn_move(Txn, SP, first),
    {ok, Txn3} = mgmtd:txn_commit(Txn2),
    ?assertEqual([{"a"}, {"z"}, {"m"}],
                 mgmtd_cfg_db:list_keys(["ord", "acl", "rule"])),
    {ok, SPm} = mgmtd_schema:lookup_path(["ord", "acl", "rule", {"m"}]),
    {ok, Txn4} = mgmtd:txn_move(Txn3, SPm, last),
    {ok, Txn5} = mgmtd:txn_commit(Txn4),
    ?assertEqual([{"a"}, {"z"}, {"m"}],
                 mgmtd_cfg_db:list_keys(["ord", "acl", "rule"])),
    {ok, SPz} = mgmtd_schema:lookup_path(["ord", "acl", "rule", {"z"}]),
    {ok, Txn6} = mgmtd:txn_move(Txn5, SPz, {'after', {"m"}}),
    {ok, Txn7} = mgmtd:txn_commit(Txn6),
    ?assertEqual([{"a"}, {"m"}, {"z"}],
                 mgmtd_cfg_db:list_keys(["ord", "acl", "rule"])),
    {ok, Txn8} = mgmtd:txn_move(Txn7, SPm, {before, {"a"}}),
    {ok, _} = mgmtd:txn_commit(Txn8),
    ?assertEqual([{"m"}, {"a"}, {"z"}],
                 mgmtd_cfg_db:list_keys(["ord", "acl", "rule"])),
    clear_rules().

delete_removes_from_order() ->
    {ok, _} = commit_paths([["ord", "acl", "rule", {"z"}, "action", "drop"],
                            ["ord", "acl", "rule", {"a"}, "action", "permit"],
                            ["ord", "acl", "rule", {"m"}, "action", "drop"]]),
    {ok, Del} = mgmtd_schema:lookup_path(["ord", "acl", "rule", {"a"}]),
    {ok, Txn} = mgmtd:txn_delete(mgmtd:txn_new(), Del),
    {ok, _} = mgmtd:txn_commit(Txn),
    ?assertEqual([{"z"}, {"m"}],
                 mgmtd_cfg_db:list_keys(["ord", "acl", "rule"])),
    {ok, _} = commit_paths([["ord", "acl", "rule", {"a"}, "action", "permit"]]),
    ?assertEqual([{"z"}, {"m"}, {"a"}],
                 mgmtd_cfg_db:list_keys(["ord", "acl", "rule"])),
    clear_rules().

show_and_lookup_preserve_order() ->
    {ok, _} = commit_paths([["ord", "acl", "rule", {"z"}, "action", "drop"],
                            ["ord", "acl", "rule", {"a"}, "action", "permit"]]),
    {ok, ListPath} = mgmtd_schema:lookup_path(["ord", "acl", "rule"]),
    {ok, Tree} = mgmtd:txn_show(undefined, ListPath),
    ?assertEqual([{"z"}, {"a"}], [K || {K, _} <- Tree]),
    {ok, AclPath} = mgmtd_schema:lookup_path(["ord", "acl"]),
    {ok, Defs} = mgmtd:txn_show(undefined, AclPath, #{defaults => true}),
    {_, RuleItems} = lists:keyfind("rule", 1, Defs),
    ?assertEqual([{"z"}, {"a"}], [K || {K, _} <- RuleItems]),
    clear_rules().

restconf_get_array_order() ->
    {ok, _} = commit_paths([["ord", "acl", "rule", {"z"}, "action", "drop"],
                            ["ord", "acl", "rule", {"a"}, "action", "permit"]]),
    {ok, #{<<"example-ordered:rule">> := Items}} =
        mgmtd_restconf_data:resource(<<"/restconf/data/example-ordered:acl/rule">>,
                                     all),
    ?assertEqual([<<"z">>, <<"a">>],
                 [maps:get(<<"name">>, I) || I <- Items]),
    clear_rules().

restconf_post_insert() ->
    BodyZ = #{<<"example-ordered:rule">> =>
                  [#{<<"name">> => <<"z">>, <<"action">> => <<"drop">>}]},
    {ok, _} = mgmtd_restconf_data:post(
                <<"/restconf/data/example-ordered:acl/rule">>, BodyZ),
    BodyA = #{<<"example-ordered:rule">> =>
                  [#{<<"name">> => <<"a">>, <<"action">> => <<"permit">>}]},
    {ok, _} = mgmtd_restconf_data:post(
                <<"/restconf/data/example-ordered:acl/rule">>, BodyA,
                #{insert => first}),
    ?assertEqual([{"a"}, {"z"}],
                 mgmtd_cfg_db:list_keys(["ord", "acl", "rule"])),
    BodyM = #{<<"example-ordered:rule">> =>
                  [#{<<"name">> => <<"m">>, <<"action">> => <<"drop">>}]},
    {ok, _} = mgmtd_restconf_data:post(
                <<"/restconf/data/example-ordered:acl/rule">>, BodyM,
                #{insert => 'after',
                  point => <<"/restconf/data/example-ordered:acl/rule=a">>}),
    ?assertEqual([{"a"}, {"m"}, {"z"}],
                 mgmtd_cfg_db:list_keys(["ord", "acl", "rule"])),
    clear_rules().

restconf_put_move() ->
    {ok, _} = commit_paths([["ord", "acl", "rule", {"z"}, "action", "drop"],
                            ["ord", "acl", "rule", {"a"}, "action", "permit"]]),
    {ok, replaced} = mgmtd_restconf_data:put(
                       <<"/restconf/data/example-ordered:acl/rule=z">>,
                       #{<<"example-ordered:rule">> =>
                             [#{<<"name">> => <<"z">>, <<"action">> => <<"drop">>}]},
                       #{insert => first}),
    ?assertEqual([{"z"}, {"a"}],
                 mgmtd_cfg_db:list_keys(["ord", "acl", "rule"])),
    clear_rules().

insert_rejected_on_system_list() ->
    Body = #{<<"example-ordered:item">> => [#{<<"name">> => <<"one">>}]},
    {error, #{http := 400, tag := <<"invalid-value">>}} =
        mgmtd_restconf_data:post(
          <<"/restconf/data/example-ordered:sys/item">>, Body,
          #{insert => first}),
    {ok, SP} = mgmtd_schema:lookup_path(["ord", "sys", "item", {"one"}]),
    {ok, Txn} = mgmtd:txn_set(mgmtd:txn_new(), SP),
    {ok, Txn2} = mgmtd:txn_commit(Txn),
    {error, {not_user_ordered, ["ord", "sys", "item"]}} =
        mgmtd:txn_move(Txn2, SP, first),
    {ok, Del} = mgmtd_schema:lookup_path(["ord", "sys", "item", {"one"}]),
    {ok, Txn3} = mgmtd:txn_delete(Txn2, Del),
    {ok, _} = mgmtd:txn_commit(Txn3).

leaf_list_order_and_move() ->
    {ok, Tags} = mgmtd_schema:lookup_path(
                   ["ord", "acl", "tag", ["c", "a", "b"]]),
    {ok, Txn} = mgmtd:txn_set(mgmtd:txn_new(), Tags),
    {ok, Txn2} = mgmtd:txn_commit(Txn),
    ?assertEqual({ok, ["c", "a", "b"]}, mgmtd:lookup(["ord", "acl", "tag"])),
    {ok, Txn3} = mgmtd:txn_move(Txn2, ["ord", "acl", "tag", {"a"}], first),
    {ok, _} = mgmtd:txn_commit(Txn3),
    ?assertEqual({ok, ["a", "c", "b"]}, mgmtd:lookup(["ord", "acl", "tag"])),
    {ok, _} = mgmtd_restconf_data:post(
                <<"/restconf/data/example-ordered:acl/tag">>,
                #{<<"example-ordered:tag">> => [<<"z">>]},
                #{insert => 'after',
                  point => <<"/restconf/data/example-ordered:acl/tag=a">>}),
    ?assertEqual({ok, ["a", "z", "c", "b"]}, mgmtd:lookup(["ord", "acl", "tag"])),
    {ok, Empty} = mgmtd_schema:lookup_path(["ord", "acl", "tag", []]),
    {ok, Txn5} = mgmtd:txn_set(mgmtd:txn_new(), Empty),
    {ok, _} = mgmtd:txn_commit(Txn5).

function_schema_ordered_by() ->
    ok = mgmtd:load_function_schema(fun fun_schema/0, #{namespace => aclfn}),
    #{ordered_by := user} = mgmtd_schema:lookup(["aclfn", "rules"]),
    {ok, P1} = mgmtd_schema:lookup_path(["aclfn", "rules", {"z"}]),
    {ok, P2} = mgmtd_schema:lookup_path(["aclfn", "rules", {"a"}]),
    Txn = mgmtd:txn_new(),
    {ok, Txn2} = mgmtd:txn_set(Txn, P1),
    {ok, Txn3} = mgmtd:txn_set(Txn2, P2),
    {ok, _} = mgmtd:txn_commit(Txn3),
    ?assertEqual([{"z"}, {"a"}],
                 mgmtd_cfg_db:list_keys(["aclfn", "rules"])),
    ok = mgmtd:remove_schema(aclfn).

%% ecli tab-completion matches with `{'$1'}`, which binds the key
%% element rather than the full key tuple. Order must still apply.
list_keys_match_follows_user_order() ->
    {ok, _} = commit_paths([["ord", "acl", "rule", {"z"}, "action", "drop"],
                            ["ord", "acl", "rule", {"a"}, "action", "permit"],
                            ["ord", "acl", "rule", {"m"}, "action", "drop"]]),
    ?assertEqual(["z", "a", "m"],
                 mgmtd_cfg_db:list_keys(["ord", "acl", "rule"], {'$1'})),
    {ok, SPm} = mgmtd_schema:lookup_path(["ord", "acl", "rule", {"m"}]),
    {ok, Txn} = mgmtd:txn_move(mgmtd:txn_new(), SPm, first),
    ?assertEqual(["m", "z", "a"],
                 mgmtd:list_keys(Txn, ["ord", "acl", "rule"], {'$1'})),
    {ok, _} = mgmtd:txn_commit(Txn),
    ?assertEqual(["m", "z", "a"],
                 mgmtd_cfg_db:list_keys(["ord", "acl", "rule"], {'$1'})),
    clear_rules().

move_unknown_point() ->
    {ok, _} = commit_paths([["ord", "acl", "rule", {"z"}, "action", "drop"]]),
    {ok, SP} = mgmtd_schema:lookup_path(["ord", "acl", "rule", {"z"}]),
    Txn = mgmtd:txn_new(),
    {error, {point_not_found, {"nope"}}} =
        mgmtd:txn_move(Txn, SP, {before, {"nope"}}),
    ok = mgmtd:txn_exit(Txn),
    clear_rules().

fun_schema() ->
    [#list{name = "rules",
           key_names = ["name"],
           ordered_by = user,
           config = true,
           children = fun() ->
                              [#leaf{name = "name", type = string}]
                      end}].

commit_paths(Paths) ->
    Txn = lists:foldl(
            fun(Path, Acc) ->
                    {ok, SP} = mgmtd_schema:lookup_path(Path),
                    {ok, Acc1} = mgmtd:txn_set(Acc, SP),
                    Acc1
            end, mgmtd:txn_new(), Paths),
    mgmtd:txn_commit(Txn).

clear_rules() ->
    case mgmtd:lookup(["ord", "acl", "rule"]) of
        {ok, Keys} ->
            Txn = lists:foldl(
                    fun(Key, Acc) when is_tuple(Key) ->
                            {ok, SP} = mgmtd_schema:lookup_path(
                                         ["ord", "acl", "rule", Key]),
                            {ok, Acc1} = mgmtd:txn_delete(Acc, SP),
                            Acc1;
                       (_, Acc) ->
                            Acc
                    end, mgmtd:txn_new(), Keys),
            {ok, _} = mgmtd:txn_commit(Txn);
        _ ->
            ok
    end.
