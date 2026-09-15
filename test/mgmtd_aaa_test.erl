-module(mgmtd_aaa_test).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    application:load(mgmtd),
    Prev = application:get_env(mgmtd, aaa),
    application:unset_env(mgmtd, aaa),
    Prev.

teardown(undefined) ->
    application:unset_env(mgmtd, aaa);
teardown({ok, Val}) ->
    application:set_env(mgmtd, aaa, Val).

aaa_test_() ->
    {setup, fun setup/0, fun teardown/1,
     [fun default_is_admin/0,
      fun empty_peer_is_default/0,
      fun root_is_admin/0,
      fun vm_uid_is_admin/0,
      fun configured_uid/0,
      fun configured_name/0,
      fun uid_beats_name/0,
      fun default_read_only/0,
      fun accesses/0]}.

default_is_admin() ->
    ?assertEqual(admin, mgmtd:aaa_role(#{})).

empty_peer_is_default() ->
    set_aaa([{default_role, read_only}]),
    ?assertEqual(read_only, mgmtd:aaa_role(#{})).

root_is_admin() ->
    set_aaa([{default_role, read_only}]),
    ?assertEqual(admin, mgmtd:aaa_role(#{uid => 0, user => "root"})).

vm_uid_is_admin() ->
    set_aaa([{default_role, read_only}]),
    Uid = list_to_integer(string:trim(os:cmd("id -u"))),
    ?assertEqual(admin, mgmtd:aaa_role(#{uid => Uid})).

configured_uid() ->
    set_aaa([{default_role, admin},
             {users, [{9999, read_only}]}]),
    ?assertEqual(read_only, mgmtd:aaa_role(#{uid => 9999, user => "guest"})).

configured_name() ->
    set_aaa([{default_role, admin},
             {users, [{"alice", read_only}]}]),
    ?assertEqual(read_only, mgmtd:aaa_role(#{uid => 42, user => "alice"})).

uid_beats_name() ->
    set_aaa([{default_role, admin},
             {users, [{7, read_only}, {"alice", admin}]}]),
    ?assertEqual(read_only, mgmtd:aaa_role(#{uid => 7, user => "alice"})).

default_read_only() ->
    set_aaa([{default_role, read_only}]),
    ?assertEqual(read_only, mgmtd:aaa_role(#{uid => 4242, user => "nobody"})).

accesses() ->
    ?assertEqual(true, mgmtd:aaa_permits(admin, write)),
    ?assertEqual(false, mgmtd:aaa_permits(read_only, write)),
    ?assertEqual(true, mgmtd:aaa_permits(read_only, read)),
    ?assertEqual([any, read, write], mgmtd:aaa_accesses(admin)),
    ?assertEqual([any, read], mgmtd:aaa_accesses(read_only)).

set_aaa(Val) ->
    application:set_env(mgmtd, aaa, Val).
