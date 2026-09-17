%%%-------------------------------------------------------------------
%%% @doc Session roles for northbound access (CLI and RESTCONF).
%%%
%%% Roles: `admin' (read and write) and `read_only' (show only).
%%% CLI mapping is from a peer identity map (`uid', `user') as produced
%%% by `ecli:peercred/1`. The Erlang API is not checked.
%%%
%%% Application env `aaa`:
%%%
%%%     {aaa, [{default_role, read_only},
%%%            {users, [{0, admin},
%%%                     {"alice", admin},
%%%                     {"bob", read_only, "s3cret"}]},
%%%            {passwords, [{"alice", "secret"}]}]}
%%%
%%% CLI lookup: configured uid, then username, then uid 0, then the uid
%%% the VM is running as, then `default_role` (library default `admin`
%%% so an unconfigured node does not lock the operator out).
%%%
%%% RESTCONF HTTP Basic: when `passwords` is non-empty, or a `users`
%%% entry is `{Name, Role, Password}`, `/restconf` requires
%%% `Authorization: Basic`. Role comes from `users` (else `default_role`).
%%% Passwords are plaintext in config for now.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_aaa).

-export([role/1, accesses/1, permits/2, authenticate/2, http_required/0]).

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

%% @doc HTTP Basic check. `{ok, Role}` or `error`.
-spec authenticate(binary() | string(), binary() | string()) -> {ok, role()} | error.
authenticate(User, Password) ->
    case lookup_password(User) of
        {ok, Expected} ->
            case password_eq(Password, Expected) of
                true ->
                    {ok, http_role(User)};
                false ->
                    error
            end;
        undefined ->
            _ = password_eq(Password, <<>>),
            error
    end.

%% @doc True when RESTCONF should demand HTTP Basic.
-spec http_required() -> boolean().
http_required() ->
    has_password_entry(passwords()) orelse has_password_entry(user_passwords()).

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
        {Uid, Role, _} ->
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
        {Name, Role, _} ->
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
        {Bin, Role, _} ->
            {ok, Role};
        false ->
            undefined
    end.

http_role(User) ->
    case name_match(User, users()) of
        {ok, Role} ->
            Role;
        undefined ->
            default_role()
    end.

lookup_password(User) ->
    case is_name(User) of
        false ->
            undefined;
        true ->
            Bin = to_bin(User),
            case match_password(Bin, passwords()) of
                {ok, _} = Hit ->
                    Hit;
                undefined ->
                    match_password(Bin, user_passwords())
            end
    end.

match_password(_User, []) ->
    undefined;
match_password(User, [{Name, Pass} | Rest]) ->
    case is_name(Name) andalso is_pass(Pass) andalso to_bin(Name) =:= User of
        true ->
            {ok, Pass};
        false ->
            match_password(User, Rest)
    end;
match_password(User, [_ | Rest]) ->
    match_password(User, Rest).

user_passwords() ->
    [{Name, Pass} || {Name, _Role, Pass} <- users(),
                     is_name(Name),
                     is_pass(Pass)].

passwords() ->
    case aaa_env(passwords) of
        L when is_list(L) ->
            L;
        M when is_map(M) ->
            maps:to_list(M);
        _ ->
            []
    end.

has_password_entry(Entries) ->
    lists:any(fun({N, P}) -> is_name(N) andalso is_pass(P);
                 (_) -> false
              end, Entries).

password_eq(Given, Expected) ->
    crypto:bytes_to_integer(
      crypto:exor(secret_hash(Given), secret_hash(Expected))) =:= 0.

secret_hash(Value) ->
    crypto:hash(sha256, to_bin(Value)).

is_name(Name) when is_list(Name), Name =/= [] ->
    true;
is_name(Name) when is_binary(Name), Name =/= <<>> ->
    true;
is_name(_) ->
    false.

is_pass(Pass) when is_list(Pass), Pass =/= [] ->
    true;
is_pass(Pass) when is_binary(Pass), Pass =/= <<>> ->
    true;
is_pass(_) ->
    false.

to_bin(B) when is_binary(B) ->
    B;
to_bin(L) when is_list(L) ->
    unicode:characters_to_binary(L).

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
