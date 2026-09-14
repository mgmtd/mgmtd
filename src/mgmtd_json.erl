%%%-------------------------------------------------------------------
%% @doc JSON encode/decode. Uses OTP `json` when present (OTP 27+),
%% otherwise jsx, returning maps with binary keys.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_json).

-export([encode/1, encode_pretty/1, decode/1]).

-spec encode(term()) -> binary().
encode(Term) ->
    case otp_json() of
        true ->
            iolist_to_binary(json:encode(Term));
        false ->
            jsx:encode(Term)
    end.

%% Pretty-printed JSON with a trailing newline, for on-disk config files.
-spec encode_pretty(term()) -> binary().
encode_pretty(Term) ->
    Bin = case otp_json() andalso erlang:function_exported(json, format, 1) of
              true ->
                  iolist_to_binary(json:format(Term));
              false ->
                  iolist_to_binary(pretty(Term, 0))
          end,
    ensure_nl(Bin).

-spec decode(binary()) -> term().
decode(Bin) when is_binary(Bin) ->
    case otp_json() of
        true ->
            json:decode(Bin);
        false ->
            jsx:decode(Bin, [return_maps])
    end.

otp_json() ->
    case code:ensure_loaded(json) of
        {module, json} ->
            erlang:function_exported(json, encode, 1)
                andalso erlang:function_exported(json, decode, 1);
        _ ->
            false
    end.

ensure_nl(<<>>) ->
    <<"\n">>;
ensure_nl(Bin) ->
    case binary:last(Bin) of
        $\n -> Bin;
        _ -> <<Bin/binary, $\n>>
    end.

pretty(Map, Indent) when is_map(Map) ->
    case maps:size(Map) of
        0 ->
            <<"{}">>;
        _ ->
            Keys = lists:sort(maps:keys(Map)),
            Pad = indent(Indent + 1),
            Body = lists:join(
                     <<",\n">>,
                     [[Pad, encode(K), <<": ">>, pretty(maps:get(K, Map), Indent + 1)]
                      || K <- Keys]),
            ["{\n", Body, $\n, indent(Indent), $}]
    end;
pretty(List, Indent) when is_list(List) ->
    case List of
        [] ->
            <<"[]">>;
        _ ->
            case lists:all(fun is_json_scalar/1, List) of
                true ->
                    encode(List);
                false ->
                    Pad = indent(Indent + 1),
                    Body = lists:join(
                             <<",\n">>,
                             [[Pad, pretty(V, Indent + 1)] || V <- List]),
                    ["[\n", Body, $\n, indent(Indent), $]]
            end
    end;
pretty(Term, _Indent) ->
    encode(Term).

is_json_scalar(null) -> true;
is_json_scalar(T) when is_boolean(T); is_number(T); is_binary(T) -> true;
is_json_scalar(_) -> false.

indent(N) ->
    binary:copy(<<"  ">>, N).
