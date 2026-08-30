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
    try initial_subscription_message(Path) of
        {error, _Reason} = Err ->
            {reply, Err, State};
        {ok, Config} ->
            Ref = erlang:make_ref(),
            MonRef = erlang:monitor(process, Pid),
            ets:insert(State#state.subs, {{Path, Pid, Ref}, []}),
            ets:insert(State#state.sub_refs, {Ref, {Path, Pid, MonRef}}),
            ets:insert(State#state.sub_pids, {Pid, {Path, Ref}}),
            Pid ! {updated_config, Ref, Config},
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


%% Provide an initial value for a subscription based on committed config
initial_subscription_message(Path) ->
    %% io:format(user, "Initial Looking up path ~p~n", [mgmtd_schema:lookup(Path)]),
    case mgmtd_schema:lookup(Path) of
        #{node_type := list} ->
            case lists:last(Path) of
                Last when is_tuple(Last) ->
                    case container_values(Path) of
                        false ->
                            {error, no_values};
                        Vals ->
                            {ok, Vals}
                    end;
                _ ->
                    %% io:format(user, "Initial  ~p~n", [mgmtd_cfg_db:list_keys(Path)]),
                    {ok, mgmtd_cfg_db:list_keys(Path)}
            end;
        #{node_type := container} ->
            case container_values(Path) of
                false ->
                    {error, no_values};
                Vals ->
                    {ok, Vals}
            end;
        #{node_type := Leaf, name := N} when Leaf == leaf; Leaf == leaf_list ->
            case leaf_value(Path) of
                {ok, Val} ->
                    {ok, [{N, Val}]};
                false ->
                    {error, no_value}
            end;
        false ->
            {error, unknown_schema_path}
    end.

%% Subscription messages on transaction commit
subscription_messages(Subscriptions, Txn) ->
    lists:foldl(fun({Path, Pid, Ref}, Acc) ->
                        case subscription_message(Path, Txn) of
                            false ->
                                Acc;
                            Msg ->
                                [{Pid, {updated_config, Ref, Msg}} | Acc]
                        end
                end, [], Subscriptions).

%% Given the subscribed path ["path", "to", "elem"] and
%% a Txn containing operations as Schema path as a list of #schema maps
subscription_message(Path, Txn) ->
    case mgmtd_schema:lookup(Path) of
        #{node_type := list} ->
            case lists:last(Path) of
                Last when is_tuple(Last) ->
                    container_values(Path, Txn);
                _ ->
                    New = mgmtd_cfg_txn:list_keys(Txn, Path, '$1'),
                    Existing = mgmtd_cfg_db:list_keys(Path),
                    if New == Existing ->
                            false;
                       true ->
                            New
                    end
            end;
        #{node_type := container} ->
            container_values(Path, Txn);
        #{node_type := Leaf, name := N} when Leaf == leaf; Leaf == leaf_list ->
            [{N, leaf_value(Path, Txn)}]
    end.

container_values(Path) ->
    container_values(Path, undefined).

container_values(Path, Txn) ->
    Children = mgmtd_schema:children(Path),
    LeafChildren = lists:filter(fun(#{node_type := Leaf}) ->
                                        Leaf == leaf orelse Leaf == leaf_list
                                end, Children),
    CVs = lists:foldl(fun(#{name := N}, Acc) ->
                              case leaf_value(Path ++ [N], Txn) of
                                  {ok, Val} ->
                                      [{N, Val} | Acc];
                                  false ->
                                      Acc
                              end
                      end, [], LeafChildren),
    case CVs of
        [] ->
            false;
        _ ->
            lists:reverse(CVs)
    end.

leaf_value(Path) ->
    leaf_value(Path, undefined).

leaf_value(Path, undefined) ->
    case mgmtd_cfg_db:lookup(Path) of
        [#cfg{value = Val}] ->
            {ok, Val};
        [] ->
            false
    end;
leaf_value(Path, Txn) ->
    {ok, New} = mgmtd_cfg_txn:get(Txn, Path),
    Old = case mgmtd_cfg_db:lookup(Path) of
              [#cfg{value = Val}] ->
                  Val;
              [] ->
                  undefined
          end,
    if New =/= Old ->
            {ok, New};
       true ->
            false
    end.

send_subscription_messages(Messages) ->
    lists:foreach(fun({Pid, Msg}) ->
                          Pid ! Msg
                  end, Messages).
