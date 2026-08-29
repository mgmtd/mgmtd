
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
                   | integer
                   | string
                   | boolean
                   | {enum, [enum_member()]}
                   | {enumeration, [enum_member()]}
                   | 'inet:ip-address'
                   | 'inet:port-number'
                   | {Mod :: atom(), Type :: term()}.

-export_type([data_type/0, enum_member/0]).

-record(container,
    {
        name :: string(),
        desc = "" :: string(),
        config = false :: boolean(),
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
        data_callback = mgmtd :: atom(),
        unique = true :: boolean(),
        config = false :: boolean(),
        children = fun() -> [] end :: fun(() -> list()),
        opts = [] :: list()
    }).

-record(leaf,
    {
        name :: string(),
        type :: data_type(),
        desc :: string(),
        default,
        mandatory = false :: boolean(),
        config = false :: boolean(),
        opts = [] :: list()
    }).

-record(leaf_list,
    {
        name :: string(),
        type :: data_type(),
        desc :: string(),
        default,
        mandatory = false :: boolean(),
        config = false :: boolean(),
        min_elements = 0 :: integer(),
        max_elements = unlimited :: unlimited | integer(),
        undefined :: undefined | boolean(),
        opts = [] :: list()
    }).