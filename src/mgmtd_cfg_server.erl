%%%-------------------------------------------------------------------
%%% @author Sean Hinde <sean@Seans-MacBook.local>
%%% @copyright (C) 2019, Sean Hinde
%%% @doc Gen server to own schema tables
%%%
%%% @end
%%% Created : 12 Sep 2019 by Sean Hinde <sean@Seans-MacBook.local>
%%%-------------------------------------------------------------------
-module(mgmtd_cfg_server).

-behaviour(gen_server).

-include("mgmtd_schema.hrl").

%% API
-export([start_link/0,
         new_txn/0,
         exit_txn/1,
         commit/1,
         subscribe/2,
         unsubscribe/1,
         show_subscriptions/0, subscriptions/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/2]).

-define(SERVER, ?MODULE).

-record(state, {
                subs = ets:new(subscriptions, []),
                sub_pids = ets:new(sub_pids, [bag]),
                sub_refs = ets:new(sub_refs, [])
               }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, Pid :: pid()} |
          {error, Error :: {already_started, pid()}} |
          {error, Error :: term()} |
          ignore.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


subscribe(Path, Pid) when is_pid(Pid); is_atom(Pid) ->
    gen_server:call(?SERVER, {subscribe, Path, Pid}).

unsubscribe(Ref) ->
    gen_server:call(?SERVER, {unsubscribe, Ref}).

show_subscriptions() ->
    Subscriptions = subscriptions(),
    lists:foreach(fun({Path, Pid,_Ref}) ->
                          io:format("~p => ~p~n",[Pid, Path])
                  end, Subscriptions).

subscriptions() ->
    gen_server:call(?SERVER, get_subscriptions).

new_txn() ->
    gen_server:call(?SERVER, new_txn).

exit_txn(Txn) ->
    gen_server:call(?SERVER, {exit_txn, Txn}).

commit(Txn) ->
    gen_server:call(?SERVER, {commit, Txn}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) -> {ok, State :: #state{}} |
          {ok, State :: term(), Timeout :: timeout()} |
          {ok, State :: term(), hibernate} |
          {stop, Reason :: term()} |
          ignore.
init([]) ->
    process_flag(trap_exit, true),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------
-spec handle_call(Request :: term(), From :: {pid(), term()}, State :: #state{}) ->
          {reply, Reply :: term(), NewState :: #state{}} |
          {reply, Reply :: term(), NewState :: #state{}, Timeout :: timeout()} |
          {reply, Reply :: term(), NewState :: #state{}, hibernate} |
          {noreply, NewState :: #state{}} |
          {noreply, NewState :: #state{}, Timeout :: timeout()} |
          {noreply, NewState :: #state{}, hibernate} |
          {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
          {stop, Reason :: term(), NewState :: #state{}}.
handle_call({subscribe, Path, Pid}, _From, State) when is_pid(Pid) ->
    try initial_subscription_ops(Path) of
        {error, _Reason} = Err ->
            {reply, Err, State};
        {ok, Ops} ->
            Ref = erlang:make_ref(),
            MonRef = erlang:monitor(process, Pid),
            ets:insert(State#state.subs, {{Path, Pid, Ref}, []}),
            ets:insert(State#state.sub_refs, {Ref, {Path, Pid, MonRef}}),
            ets:insert(State#state.sub_pids, {Pid, {Path, Ref}}),
            Pid ! {config_change, Ref, Ops},
            {reply, {ok, Ref}, State}
    catch
        error:db_not_initialized ->
            {reply, {error, db_not_initialized}, State}
    end;
handle_call({unsubscribe, Ref}, _From, State) ->
    case ets:lookup(State#state.sub_refs, Ref) of
        [{Ref, {Path, Pid, MonRef}}] ->
            erlang:demonitor(MonRef),
            ets:delete(State#state.subs, {Path, Pid, Ref}),
            ets:delete(State#state.sub_refs, Ref),
            ets:delete_object(State#state.sub_pids, {Pid, {Path, Ref}}),
            {reply, ok, State};
        [] ->
            {reply, ok, State}
    end;
handle_call(get_subscriptions, _From, State) ->
    Subs = ets:tab2list(State#state.subs),
    {reply, Subs, State};
handle_call(new_txn, _From, State) ->
    Txn = mgmtd_cfg_txn:new(),
    {reply, Txn, State};
handle_call({exit_txn, Txn}, _From, State) ->
    mgmtd_cfg_txn:exit_txn(Txn),
    {reply, ok, State};
handle_call({commit, Txn}, _From, State) ->
    %% Generate all subscription messages
    Subscriptions = [K || {K,[]} <- ets:tab2list(State#state.subs)],
    %% io:format(user, "with subscriptions ~p~n", [Subscriptions]),
    Messages = subscription_messages(Subscriptions, Txn),
    case mgmtd_cfg_txn:commit(Txn) of
        {ok, Txn2} ->
            send_subscription_messages(Messages),
            {reply, {ok, Txn2}, State};
        Err ->
            {reply, Err, State}
    end;
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request :: term(), State :: #state{}) ->
          {noreply, NewState :: #state{}} |
          {noreply, NewState :: #state{}, Timeout :: timeout()} |
          {noreply, NewState :: #state{}, hibernate} |
          {stop, Reason :: term(), NewState :: #state{}}.
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Info :: timeout() | term(), State :: #state{}) ->
          {noreply, NewState :: #state{}} |
          {noreply, NewState :: #state{}, Timeout :: timeout()} |
          {noreply, NewState :: #state{}, hibernate} |
          {stop, Reason :: normal | term(), NewState :: #state{}}.
handle_info({'DOWN', _, _, Pid, _}, State) ->
    %% Process down, remove all the subscriptions of this process
    case ets:lookup(State#state.sub_pids, Pid) of
        [] ->
            ok;
        Recs ->
            lists:foreach(
              fun({_Pid, {Path, Ref}}) ->
                      [{Ref, {Path, Pid, MonRef}}] =
                          ets:lookup(State#state.sub_refs, Ref),
                      erlang:demonitor(MonRef),
                      ets:delete(State#state.sub_refs, Ref),
                      ets:delete(State#state.subs, {Path, Pid, Ref})
              end, Recs),
            %% Delete all entries from the duplicate_bag with this Pid
            ets:delete(State#state.sub_pids, Pid)
    end,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason :: normal | shutdown | {shutdown, term()} | term(),
                State :: #state{}) -> any().
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn :: term() | {down, term()},
                  State :: #state{},
                  Extra :: term()) -> {ok, NewState :: term()} |
          {error, Reason :: term()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called for changing the form and appearance
%% of gen_server status when it is returned from sys:get_status/1,2
%% or when it appears in termination error logs.
%% @end
%%--------------------------------------------------------------------
-spec format_status(Opt :: normal | terminate,
                    Status :: list()) -> Status :: term().
format_status(_Opt, Status) ->
    Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% Snapshot as if going from empty → committed config.
initial_subscription_ops(Path) ->
    case validate_sub_path(Path) of
        {error, _} = Err ->
            Err;
        ok ->
            {ok, subscription_ops(Path, empty, committed)}
    end.

%% Subscription messages on transaction commit
subscription_messages(Subscriptions, Txn) ->
    lists:foldl(fun({Path, Pid, Ref}, Acc) ->
                        case subscription_ops(Path, committed, {txn, Txn}) of
                            [] ->
                                Acc;
                            Ops ->
                                [{Pid, {config_change, Ref, Ops}} | Acc]
                        end
                end, [], Subscriptions).

send_subscription_messages(Messages) ->
    lists:foreach(fun({Pid, Msg}) ->
                          Pid ! Msg
                  end, Messages).

validate_sub_path(Path) ->
    case mgmtd_schema:lookup(Path) of
        false ->
            {error, unknown_schema_path};
        #{} ->
            case bad_list_keys(Path, []) of
                true ->
                    {error, unknown_schema_path};
                false ->
                    ok
            end
    end.

bad_list_keys([], _Acc) ->
    false;
bad_list_keys([Key | Rest], Acc) when is_tuple(Key) ->
    case mgmtd_schema:lookup(lists:reverse(Acc)) of
        #{node_type := list} ->
            bad_list_keys(Rest, [Key | Acc]);
        _ ->
            true
    end;
bad_list_keys([Name | Rest], Acc) ->
    bad_list_keys(Rest, [Name | Acc]).

%% Longest stored prefix we need to read. Stop at a list when the
%% instance is omitted (match every item). Stop at the list item when
%% a key is given so add/delete of that instance is visible.
db_prefix(Path) ->
    db_prefix(Path, []).

db_prefix([], Acc) ->
    lists:reverse(Acc);
db_prefix([Key | Rest], Acc) when is_tuple(Key) ->
    db_prefix(Rest, [Key | Acc]);
db_prefix([Name | Rest], Acc) ->
    Next = lists:reverse([Name | Acc]),
    case mgmtd_schema:lookup(Next) of
        #{node_type := list} ->
            case Rest of
                [Key | _] when is_tuple(Key) ->
                    lists:reverse([Key, Name | Acc]);
                _ ->
                    Next
            end;
        _ ->
            db_prefix(Rest, [Name | Acc])
    end.

subscription_ops(SubPath, OldSrc, NewSrc) ->
    Prefix = db_prefix(SubPath),
    OldMap = index_rows(rows_at(Prefix, OldSrc)),
    NewMap = index_rows(rows_at(Prefix, NewSrc)),
    order_ops(diff_ops(SubPath, OldMap, NewMap)).

rows_at(_Prefix, empty) ->
    [];
rows_at(Prefix, committed) ->
    mgmtd_cfg_db:match_object(row_pattern(Prefix));
rows_at(Prefix, {txn, Txn}) ->
    mgmtd_cfg_txn:match_object(Txn, row_pattern(Prefix)).

row_pattern(Prefix) ->
    #cfg{path = mgmtd_schema:ets_tail(Prefix),
         _ = mgmtd_schema:ets_pat('_')}.

index_rows(Rows) ->
    maps:from_list([{Path, {NodeType, Value}}
                    || #cfg{path = Path, node_type = NodeType, value = Value} <- Rows]).

diff_ops(SubPath, OldMap, NewMap) ->
    OldPaths = maps:keys(OldMap),
    NewPaths = maps:keys(NewMap),
    Deleted = OldPaths -- NewPaths,
    Created = NewPaths -- OldPaths,
    Shared = NewPaths -- Created,
    DelOps = lists:filtermap(
               fun(P) ->
                       case maps:get(P, OldMap) of
                           {list_key, _} ->
                               keep_if(SubPath, {delete, lists:droplast(P), lists:last(P)});
                           {Leaf, OldV} when Leaf =:= leaf; Leaf =:= leaf_list ->
                               %% Delete+re-add of the same list item is
                               %% squashed: the instance stays, so a vanished
                               %% leaf is a set back to default (or undefined).
                               Parent = lists:droplast(P),
                               case maps:is_key(Parent, NewMap) of
                                   true ->
                                       NewV = leaf_default(P),
                                       case NewV =:= OldV of
                                           true ->
                                               false;
                                           false ->
                                               keep_if(SubPath, {set, P, NewV})
                                       end;
                                   false ->
                                       false
                               end;
                           _ ->
                               false
                       end
               end, Deleted),
    AddOps = lists:filtermap(
               fun(P) ->
                       case maps:get(P, NewMap) of
                           {list_key, _} ->
                               keep_if(SubPath, {add, lists:droplast(P), lists:last(P)});
                           {Leaf, Val} when Leaf =:= leaf; Leaf =:= leaf_list ->
                               keep_if(SubPath, {set, P, Val});
                           _ ->
                               false
                       end
               end, Created),
    SetOps = lists:filtermap(
               fun(P) ->
                       case {maps:get(P, OldMap), maps:get(P, NewMap)} of
                           {{Leaf, OldV}, {Leaf, NewV}}
                             when (Leaf =:= leaf orelse Leaf =:= leaf_list),
                                  OldV =/= NewV ->
                               keep_if(SubPath, {set, P, NewV});
                           _ ->
                               false
                       end
               end, Shared),
    DelOps ++ AddOps ++ SetOps.

keep_if(SubPath, Op) ->
    case op_matches(SubPath, Op) of
        true -> {true, Op};
        false -> false
    end.

leaf_default(Path) ->
    case mgmtd_schema:get_default(Path) of
        {ok, Default} ->
            Default;
        _ ->
            undefined
    end.

op_matches(SubPath, {set, Path, _Value}) ->
    case path_rel(SubPath, Path) of
        equal -> true;
        subtree -> true;
        _ -> false
    end;
op_matches(SubPath, {add, ListPath, Key}) ->
    path_rel(SubPath, ListPath ++ [Key]) =/= mismatch;
op_matches(SubPath, {delete, ListPath, Key}) ->
    path_rel(SubPath, ListPath ++ [Key]) =/= mismatch.

%% Walk subscription path vs a stored data path. List keys in the data
%% may be omitted from the subscription (match every instance).
path_rel([], []) ->
    equal;
path_rel([], _Data) ->
    subtree;
path_rel(_Sub, []) ->
    ancestor;
path_rel([S | Ss], [D | Ds]) when S =:= D ->
    path_rel(Ss, Ds);
path_rel([S | _Ss], [D | _Ds]) when is_tuple(S), is_tuple(D) ->
    mismatch;
path_rel(Sub, [D | Ds]) when is_tuple(D) ->
    path_rel(Sub, Ds);
path_rel(_Sub, _Data) ->
    mismatch.

order_ops(Ops) ->
    {Deletes, Rest} = lists:partition(fun is_delete/1, Ops),
    {Adds, Sets} = lists:partition(fun is_add/1, Rest),
    sort_deletes(Deletes) ++ sort_adds(Adds) ++ sort_sets(Sets).

is_delete({delete, _, _}) -> true;
is_delete(_) -> false.

is_add({add, _, _}) -> true;
is_add(_) -> false.

sort_deletes(Deletes) ->
    lists:sort(fun({delete, P1, K1}, {delete, P2, K2}) ->
                       L1 = length(P1),
                       L2 = length(P2),
                       if L1 =:= L2 -> {P1, K1} =< {P2, K2};
                          true -> L1 > L2
                       end
               end, Deletes).

sort_adds(Adds) ->
    lists:sort(fun({add, P1, K1}, {add, P2, K2}) ->
                       L1 = length(P1),
                       L2 = length(P2),
                       if L1 =:= L2 -> {P1, K1} =< {P2, K2};
                          true -> L1 < L2
                       end
               end, Adds).

sort_sets(Sets) ->
    lists:sort(fun({set, P1, _}, {set, P2, _}) ->
                       P1 =< P2
               end, Sets).
