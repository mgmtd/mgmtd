%%%-------------------------------------------------------------------
%%% @doc Test-only rpc/action callback.
%%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_test_rpc).

-behaviour(mgmtd_rpc).

-export([invoke/2]).

invoke(["rpc", "restart"], _Input) ->
    {ok, empty};
invoke(["rpc", "echo"], Input) ->
    In = maps:get("in", Input, ""),
    {ok, #{"out" => "echo:" ++ In}};
invoke(["rpc", "add"], Input) ->
    {ok, #{"sum" => maps:get("a", Input) + maps:get("b", Input)}};
invoke(["rpc", "box", "items", Key, "reset"], _Input) ->
    Name = case Key of
               {N} -> N;
               N when is_list(N) -> N
           end,
    {ok, #{"state" => "reset:" ++ Name}};
invoke(_Path, _Input) ->
    {error, unknown_rpc}.
