%%%-------------------------------------------------------------------
%% @doc RFC 8040 error envelope (`ietf-restconf:errors`).
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_error).

-export([reply/3, encode/1]).

-define(JSON, <<"application/yang-data+json">>).

-spec reply(cowboy_req:req(), pos_integer(), map()) -> cowboy_req:req().
reply(Req, Status, Err) ->
    cowboy_req:reply(Status,
                     #{<<"content-type">> => ?JSON},
                     encode(Err),
                     Req).

-spec encode(map()) -> binary().
encode(Err) ->
    Error0 = #{<<"error-type">> => type(Err),
               <<"error-tag">> => tag(Err),
               <<"error-message">> => message(Err)},
    Error = case maps:get(path, Err, undefined) of
                undefined ->
                    Error0;
                Path ->
                    Error0#{<<"error-path">> => to_bin(Path)}
            end,
    iolist_to_binary(
      json:encode(#{<<"ietf-restconf:errors">> =>
                        #{<<"error">> => [Error]}})).

type(#{type := Type}) ->
    to_bin(Type);
type(_) ->
    <<"application">>.

tag(#{tag := Tag}) ->
    to_bin(Tag);
tag(_) ->
    <<"operation-failed">>.

message(#{message := Msg}) ->
    to_bin(Msg);
message(#{tag := Tag}) ->
    to_bin(Tag);
message(_) ->
    <<"error">>.

to_bin(B) when is_binary(B) ->
    B;
to_bin(L) when is_list(L) ->
    unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) ->
    atom_to_binary(A, utf8).
