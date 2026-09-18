
%% -define(DEBUG, 1).

-ifdef(DEBUG).
-define(DBG(DATA), io:format(user, "[~p:~p] ~p~n",[?MODULE, ?LINE, DATA])).
-define(DBG(FORMAT, ARGS), io:format(user, "[~p:~p] " ++ FORMAT,[?MODULE, ?LINE] ++ ARGS)).
-else.
-define(DBG(DATA), ok).
-define(DBG(FORMAT, ARGS), ok).
-endif.

%% Prefix is the operational identity (CLI token, sys.config app key,
%% ETS key). Namespace on a loaded schema info is always a URI string
%% (YANG namespace, or urn:mgmtd:<prefix> for JSON / Erlang). The
%% RESTCONF / RFC 7951 module name is `module` and may differ from
%% the prefix (YANG `ietf-interfaces` vs prefix `if`).
-type prefix() :: atom().
-type ns() :: prefix().
-type namespace() :: prefix() | string().
-type list_key() :: tuple().
-type path_node() :: string() | list_key() | '_'.
-type item_path() :: [path_node()].
-type schema_path() :: [string() | '_'].
-type node_type() :: container | leaf | list | leaf_list | list_key
                   | rpc | action | notification.
-type cmd_type() :: show | set | delete | move | schema | operations.
-type schema_source() :: json | function | yang | unknown.
-type schema_info() :: #{prefix := prefix(),
                         module := string(),
                         namespace := string(),
                         source := schema_source(),
                         revision := undefined | string(),
                         features := [string()],
                         yang_source => binary()}.

-define(is_leaf(NodeType), NodeType == leaf orelse NodeType == leaf_list).
-define(DEFAULT_NS, default).

%% Record stored in the single mgmtd_commands ETS table, keyed by
%% {Path, Prefix}. Named prefixes are loaded as a real root container;
%% descendant paths start with the prefix name. Default prefix is silent.
-record(schema,
        {path :: {schema_path(), prefix()},     % Schema path + prefix
         prefix = ?DEFAULT_NS :: prefix(),
         node_type :: node_type(),  % container | leaf | list | leaf_list | rpc | action | notification
         name :: string(),
         desc :: string(),
         type :: mgmtd:data_type() | undefined,
         default,
         key_names = [] :: [string()], % {NodeName1, NodeName2, Nodename3} for lists
         data_callback :: atom(),
         min_elements = 0 :: integer(),
         max_elements = unlimited :: unlimited | integer(),
         ordered_by = system :: system | user,
         pattern :: undefined | string(),
         mandatory = false :: boolean(),
         has_list = false :: boolean(),
         has_user_ordered_list = false :: boolean(),
         config = false :: boolean(),
         opts = [] :: list()}).

-type map_node() :: #{role := schema,
                      path := schema_path(),
                      ns => prefix(),
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
                      ordered_by => system | user,
                      pattern => string(),
                      mandatory => boolean(),
                      config => boolean(),
                      data_callback => atom(),
                      cmd_type => cmd_type(),
                      has_list => boolean(),
                      has_user_ordered_list => boolean(),
                      opts => list(),
                      origin_module => string() | undefined,
                      children => function() }.

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
