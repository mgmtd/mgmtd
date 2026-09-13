%%%-------------------------------------------------------------------
%% @doc JSON encode/decode via jsx, with maps like OTP 27 json.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_json).

-export([encode/1, decode/1]).

-spec encode(term()) -> binary().
encode(Term) ->
    jsx:encode(Term).

-spec decode(binary()) -> term().
decode(Bin) when is_binary(Bin) ->
    jsx:decode(Bin, [return_maps]).
