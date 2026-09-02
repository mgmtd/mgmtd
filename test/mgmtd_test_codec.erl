%%%-------------------------------------------------------------------
%%% @doc Test-only sys.config codec: a keyed list packed as tagged tuples.
%%%
%%% Default (schema / `#cfg{}`) value:
%%%
%%%     [[{name, "a"}, {n, 1}], [{name, "b"}, {n, 2}]]
%%%
%%% Wire value:
%%%
%%%     [{item, a, #{n => 1}}, {item, b, #{n => 2}}]
%%%
%%% Concrete application codecs (OTP logger, …) live with the host schema,
%%% not in mgmtd.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_test_codec).

-behaviour(mgmtd_codec).

-export([export/1, import/1, schema/0]).

-include("../include/mgmtd.hrl").

-spec export(term()) -> term().
export(Items) when is_list(Items) ->
    [export_item(Item) || Item <- Items];
export(Other) ->
    throw({export_error, {invalid_list, Other}}).

-spec import(term()) -> term().
import(Items) when is_list(Items) ->
    [import_item(Item) || Item <- Items];
import(Other) ->
    throw({import_error, {invalid_list, Other}}).

schema() ->
    [#list{name = "items",
           desc = "Codec demo list",
           key_names = ["name"],
           config = true,
           opts = [{codec, mgmtd_test_codec}],
           children = fun item_schema/0}].

item_schema() ->
    [#leaf{name = "name", desc = "Item name", type = string},
     #leaf{name = "n", desc = "Integer payload", type = int32}].

%%--------------------------------------------------------------------
export_item(Props) when is_list(Props) ->
    Name = required(Props, name),
    N = required(Props, n),
    {item, to_atom(Name), #{n => N}};
export_item(Other) ->
    throw({export_error, {invalid_item, Other}}).

import_item({item, Name, #{n := N}}) ->
    [{name, from_atom(Name)}, {n, N}];
import_item(Other) ->
    throw({import_error, {unsupported_item, Other}}).

required(Props, Key) ->
    case lists:keyfind(Key, 1, Props) of
        {_, V} ->
            V;
        false ->
            throw({export_error, {missing, Key}})
    end.

to_atom(A) when is_atom(A) ->
    A;
to_atom(S) when is_list(S) ->
    list_to_atom(S).

from_atom(A) when is_atom(A) ->
    atom_to_list(A);
from_atom(S) when is_list(S) ->
    S.
