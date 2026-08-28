%%%-------------------------------------------------------------------
%% @doc mgmtd top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(mgmtd_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-include("mgmtd_schema.hrl").

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([]) ->
    SupFlags =
        #{strategy => one_for_all,
          intensity => 0,
          period => 1},

    Server =
        #{id => mgmtd_cfg_server,
          start => {mgmtd_cfg_server, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [mgmtd_cfg_server]},

    init_tabs(),

    {ok, {SupFlags, [Server]}}.

%% internal functions
init_tabs() ->
    ets:new(mgmtd_meta, [public, named_table]),
    ets:new(mgmtd_commands, [public, named_table, {keypos, #schema.path}]).
