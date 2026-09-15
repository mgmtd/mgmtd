%%%-------------------------------------------------------------------
%%% @doc Session roles for northbound access (CLI first).
%%%
%%% Roles: `admin' (read and write) and `read_only' (show only).
%%% Mapping is from a peer identity map (`uid', `user') as produced by
%%% `ecli:peercred/1`. The Erlang API is not checked.
%%%
%%% Application env `aaa`:
%%%
%%%     {aaa, [{default_role, read_only},
%%%            {users, [{0, admin}, {"alice", admin}]}]}
%%%
%%% Lookup: configured uid, then username, then uid 0, then the uid
%%% the VM is running as, then `default_role` (library default `admin`
%%% so an unconfigured node does not lock the operator out).
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_aaa).

-export([role/1, accesses/1, permits/2]).

-type role() :: admin | read_only.
-type access() :: any | read | write.
-type peer() :: map().

-export_type([role/0, access/0, peer/0]).

-spec role(peer()) -> role().
role(Peer) when is_map(Peer) ->
    Uid = maps:get(uid, Peer, undefined),
    User = maps:get(user, Peer, undefined),
    Users = users(),
    case lookup_user(Uid, User, Users) of
        {ok, Role} ->
            Role;
        undefined ->
            implicit_role(Uid)
    end.

implicit_role(0) ->
    admin;
implicit_role(Uid) ->
    case vm_uid() of
        Uid when is_integer(Uid) ->
            admin;
        _ ->
            default_role()
    end.

-spec accesses(role()) -> [access()].
accesses(admin) ->
    [any, read, write];
accesses(read_only) ->
    [any, read];
accesses(_) ->
    [any, read].

-spec permits(role(), access()) -> boolean().
permits(Role, Access) ->
    lists:member(Access, accesses(Role)).

lookup_user(Uid, User, Users) ->
    case uid_match(Uid, Users) of
        {ok, _} = Hit ->
            Hit;
        undefined ->
            name_match(User, Users)
    end.

uid_match(Uid, Users) when is_integer(Uid) ->
    case lists:keyfind(Uid, 1, Users) of
        {Uid, Role} ->
            {ok, Role};
        false ->
            undefined
    end;
uid_match(_, _) ->
    undefined.

name_match(Name, Users) when is_list(Name), Name =/= [] ->
    case lists:keyfind(Name, 1, Users) of
        {Name, Role} ->
            {ok, Role};
        false ->
            name_match_bin(Name, Users)
    end;
name_match(Name, Users) when is_binary(Name) ->
    name_match(binary_to_list(Name), Users);
name_match(_, _) ->
    undefined.

name_match_bin(Name, Users) ->
    Bin = list_to_binary(Name),
    case lists:keyfind(Bin, 1, Users) of
        {Bin, Role} ->
            {ok, Role};
        false ->
            undefined
    end.

users() ->
    case aaa_env(users) of
        L when is_list(L) ->
            L;
        _ ->
            []
    end.

default_role() ->
    case aaa_env(default_role) of
        admin ->
            admin;
        read_only ->
            read_only;
        _ ->
            admin
    end.

aaa_env(Key) ->
    case application:get_env(mgmtd, aaa) of
        {ok, L} when is_list(L) ->
            proplists:get_value(Key, L);
        {ok, #{Key := V}} ->
            V;
        _ ->
            undefined
    end.

vm_uid() ->
    case string:trim(os:cmd("id -u")) of
        "" ->
            undefined;
        S ->
            try list_to_integer(S) of
                N -> N
            catch
                error:badarg -> undefined
            end
    end.
