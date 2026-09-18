
%% YANG enumeration member. Canonical stored value is the name string.
%% {Name, Description} is the compact function-schema form; the map
%% form matches YANG enum (name / description / optional integer value).
-type enum_member() :: string()
                     | {string(), string()}
                     | #{name := string(),
                         desc => string(),
                         value => integer()}.

%% `{enum, Members}' and `{enumeration, Members}' are type constructors,
%% not `{Module, Type}' callbacks. `{Mod, Type}' is only for user modules.
%% `{integer-type, Range}' is a JSON Schema / YANG range restriction.
-type int_range() :: [{min, integer()} | {max, integer()}].
-type data_type() :: uint8
                   | uint16
                   | uint32
                   | uint64
                   | int8
                   | int16
                   | int32
                   | int64
                   | {uint8, int_range()}
                   | {uint16, int_range()}
                   | {uint32, int_range()}
                   | {uint64, int_range()}
                   | {int8, int_range()}
                   | {int16, int_range()}
                   | {int32, int_range()}
                   | {int64, int_range()}
                   | decimal64
                   | {decimal64, pos_integer()}
                   | {decimal64, pos_integer(), int_range()}
                   | integer
                   | string
                   | boolean
                   | empty
                   | binary
                   | 'instance-identifier'
                   | {'instance-identifier', boolean()}
                   | {enum, [enum_member()]}
                   | {enumeration, [enum_member()]}
                   | 'inet:ip-address'
                   | 'inet:port-number'
                   | {identityref, string()}
                   | {leafref, string()}
                   | {leafref, string(), boolean()}
                   | {union, list()}
                   | {bits, list()}
                   | {Mod :: atom(), Type :: term()}.

-export_type([data_type/0, enum_member/0]).

-record(container,
    {
        name :: string(),
        desc = "" :: string(),
        config = false :: boolean(),
        data_callback :: atom(),
        children = fun() -> [] end :: fun(() -> list()),
        opts = [] :: list()
    }).

-record(list,
    {
        name :: string(),
        desc = "" :: string(),
        key_names = [] :: [string()],
        min_elements = 0 :: integer(),
        max_elements = unlimited :: unlimited | integer(),
        ordered_by = system :: system | user,
        data_callback :: atom(),
        unique = true :: boolean(),
        config = false :: boolean(),
        children = fun() -> [] end :: fun(() -> list()),
        opts = [] :: list()
    }).

-record(leaf,
    {
        name :: string(),
        type :: data_type(),
        desc = "" :: string(),
        default,
        mandatory = false :: boolean(),
        config = false :: boolean(),
        data_callback :: atom(),
        opts = [] :: list()
    }).

-record(leaf_list,
    {
        name :: string(),
        type :: data_type(),
        desc = "" :: string(),
        default,
        mandatory = false :: boolean(),
        config = false :: boolean(),
        data_callback :: atom(),
        min_elements = 0 :: integer(),
        max_elements = unlimited :: unlimited | integer(),
        ordered_by = system :: system | user,
        undefined :: undefined | boolean(),
        opts = [] :: list()
    }).

%% Top-level YANG rpc, or the same shape from a function schema.
%% `input` / `output` are thunks of data nodes (not the implicit
%% containers). `callback` is a `mgmtd_rpc` module; if undefined the
%% schema load-option `callback` is used.
-record(rpc,
    {
        name :: string(),
        desc = "" :: string(),
        callback :: atom(),
        input = fun() -> [] end :: fun(() -> list()),
        output = fun() -> [] end :: fun(() -> list()),
        opts = [] :: list()
    }).

%% Nested YANG action (container / list child). Same payload shape as rpc.
-record(action,
    {
        name :: string(),
        desc = "" :: string(),
        callback :: atom(),
        input = fun() -> [] end :: fun(() -> list()),
        output = fun() -> [] end :: fun(() -> list()),
        opts = [] :: list()
    }).

%% YANG notification. Compiled into the schema; not delivered (no streams).
-record(notification,
    {
        name :: string(),
        desc = "" :: string(),
        children = fun() -> [] end :: fun(() -> list()),
        opts = [] :: list()
    }).