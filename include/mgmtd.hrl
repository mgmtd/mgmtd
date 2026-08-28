
-type data_type() :: uint8
                   | uint16
                   | uint32
                   | uint64
                   | int8
                   | int16
                   | int32
                   | int64
                   | decimal64
                   | integer
                   | string
                   | boolean
                   | {enum, [string() | {string(), string()}]}
                   | 'inet:ip-address'
                   | 'inet:port-number'
                   | {Mod :: atom(), Type :: atom()}.

-export_type([data_type/0]).

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