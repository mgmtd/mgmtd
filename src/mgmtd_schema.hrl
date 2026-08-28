
%% -define(DEBUG, 1).

-ifdef(DEBUG).
-define(DBG(DATA), io:format(user, "[~p:~p] ~p~n",[?MODULE, ?LINE, DATA])).
-define(DBG(FORMAT, ARGS), io:format(user, "[~p:~p] " ++ FORMAT,[?MODULE, ?LINE] ++ ARGS)).
-else.
-define(DBG(DATA), ok).
-define(DBG(FORMAT, ARGS), ok).
-endif.

-type ns() :: atom().
-type list_key() :: tuple().
-type path_node() :: string() | list_key() | '_'.
-type item_path() :: [path_node()].
-type schema_path() :: [string() | '_'].
-type node_type() :: container | leaf | list | leaf_list | list_key.
-type cmd_type() :: show | set | delete.

%% Record stored in schema ets tables. One table for each namespace
-record(schema,
        {path :: {schema_path(), ns()},     % Full path to item in tree
         prefix = "" :: string(),
         node_type :: node_type(),  % container | leaf | list | leaf_list
         name :: string(),
         desc :: string(),
         type :: mgmtd:data_type() | undefined,
         default,
         key_names = [] :: [string()], % {NodeName1, NodeName2, Nodename3} for lists
         data_callback :: atom(),
         min_elements = 0 :: integer(),
         max_elements = unlimited :: unlimited | integer(),
         pattern :: undefined | string(),
         mandatory = false :: boolean(),
         has_list = false :: boolean(),
         config = false :: boolean()}).

-type map_node() :: #{role := schema,
                      path := schema_path(),
                      node_type := node_type(),
                      name := string(),
                      desc => string(),
                      type => any(),
                      default => any(),
                      key_names => [string()],
                      key_values => [term()],
                      key_internal_values => [term()],
                      min_elements => integer(),
                      max_elements => unlimited | integer(),
                      pattern => string(),
                      mandatory => boolean(),
                      config => boolean(),
                      data_callback => atom(),
                      cmd_type => cmd_type(),
                      has_list => boolean(),
                      children => function() }.

-define(is_leaf(NodeType), NodeType == leaf orelse NodeType == leaf_list).
-define(DEFAULT_NS, default_ns).

-type full_schema_path() :: [#schema{}].
-type map_path() :: [map_node()].
-export_type([full_schema_path/0, map_path/0, item_path/0]).

%% Record we store in the configuration database after validation against the schema.
-record(cfg,
        {
         path :: item_path(),
         name :: string() | list_key(),
         node_type = container :: node_type(),
         value :: any()
        }).
