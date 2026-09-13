%%%-------------------------------------------------------------------
%% @doc RFC 8040 api-path ↔ mgmtd item_path.
%%
%% The named-prefix container is CLI-only: `/restconf/data/example:server`
%% maps to `["example", "server", ...]`, never to a RESTCONF node named
%% `example`. Default prefix has no extra path token.
%% @end
%%%-------------------------------------------------------------------
-module(mgmtd_restconf_path).

-export([parse/1, data_uri/1]).

-include("mgmtd_schema.hrl").

-type content() :: all | config | nonconfig.
-type data_ref() :: #{module := string(),
                      prefix := atom(),
                      item_path := item_path(),
                      schema := map()}.
-type parse_ok() :: datastore | yanglib_state | yanglib_id | data_ref().

-export_type([content/0, data_ref/0, parse_ok/0]).

%% {ok, datastore} |
%% {ok, yanglib_state} |
%% {ok, yanglib_id} |
%% {ok, #{module, prefix, item_path, schema}} |
%% {error, #{tag, message}}
-spec parse(binary() | string()) -> {ok, parse_ok()} | {error, map()}.
parse(Path) when is_list(Path) ->
    parse(list_to_binary(Path));
parse(<<"/restconf/data">>) ->
    {ok, datastore};
parse(<<"/restconf/data/">>) ->
    {ok, datastore};
parse(<<"/restconf/data/", Rest/binary>>) ->
    parse_segments(split_slash(Rest), undefined, undefined, []);
parse(_) ->
    {error, #{tag => <<"invalid-value">>,
              http => 400,
              message => <<"not a RESTCONF data resource">>}}.

parse_segments([], undefined, _Ns, []) ->
    {ok, datastore};
parse_segments([], _Mod, _Ns, Path) ->
    finish(Path);
parse_segments([Seg | Rest], CurMod, Ns, Path) ->
    case parse_ident(Seg, CurMod) of
        {error, _} = Err ->
            Err;
        {Mod, Name, Keys} ->
            case {CurMod, Path} of
                {undefined, []} ->
                    enter_module(Mod, Name, Keys, Rest);
                _ ->
                    enter_node(Mod, Ns, Name, Keys, Rest, Path)
            end
    end.

enter_module("ietf-yang-library", "modules-state", undefined, []) ->
    {ok, yanglib_state};
enter_module("ietf-yang-library", "modules-state", undefined,
             [<<"module-set-id">>]) ->
    {ok, yanglib_id};
enter_module("ietf-yang-library", _Name, _Keys, _Rest) ->
    {error, #{tag => <<"invalid-value">>,
              http => 404,
              message => <<"unknown ietf-yang-library node">>}};
enter_module(Mod, Name, Keys, Rest) ->
    case mgmtd_restconf_yanglib:find_module(Mod) of
        error ->
            {error, #{tag => <<"invalid-value">>,
                      http => 404,
                      message => "unknown module " ++ Mod}};
        {ok, #{source := builtin}} ->
            {error, #{tag => <<"invalid-value">>,
                      http => 404,
                      message => "unknown data node in " ++ Mod}};
        {ok, #{prefix := Prefix}} ->
            Base = prefix_base(Prefix),
            enter_node(Mod, Prefix, Name, Keys, Rest, Base)
    end.

enter_node(Mod, Ns, Name, Keys, Rest, Path) ->
    Child = Path ++ [Name],
    case mgmtd_schema:lookup(Child) of
        false ->
            {error, #{tag => <<"invalid-value">>,
                      http => 404,
                      message => "unknown data node " ++ Name}};
        Schema ->
            case Keys of
                undefined ->
                    descend(Mod, Ns, Name, Rest, Child, Schema);
                KeyStrs ->
                    enter_keyed(Mod, Ns, Name, KeyStrs, Rest, Child, Schema)
            end
    end.

descend(Mod, Ns, _Name, Rest, Child, Schema) ->
    case {maps:get(node_type, Schema), Rest} of
        {list, [_ | _]} ->
            {error, #{tag => <<"invalid-value">>,
                      http => 400,
                      message => <<"list instance requires keys">>}};
        {Leaf, [_ | _]} when Leaf =:= leaf; Leaf =:= leaf_list ->
            {error, #{tag => <<"invalid-value">>,
                      http => 400,
                      message => <<"cannot descend below a leaf">>}};
        _ ->
            parse_segments(Rest, Mod, Ns, Child)
    end.

enter_keyed(Mod, Ns, _ListName, KeyStrs, Rest, Child, #{node_type := list} = Schema) ->
    case key_tuple(Child, Schema, KeyStrs) of
        {ok, Key} ->
            parse_segments(Rest, Mod, Ns, Child ++ [Key]);
        {error, _} = Err ->
            Err
    end;
enter_keyed(Mod, Ns, _Name, [Val], Rest, Child, #{node_type := leaf_list}) ->
    parse_segments(Rest, Mod, Ns, Child ++ [{Val}]);
enter_keyed(_Mod, _Ns, Name, _Keys, _Rest, _Child, _Schema) ->
    {error, #{tag => <<"invalid-value">>,
              http => 400,
              message => Name ++ " is not a list"}}.

finish(Path) ->
    case mgmtd_schema:lookup(Path) of
        false ->
            {error, #{tag => <<"invalid-value">>,
                      http => 404,
                      message => <<"unknown data node">>}};
        Schema ->
            {Ns, _} = mgmtd_schema:split_item_path(Path),
            Module = module_name(Ns),
            {ok, #{module => Module,
                   prefix => Ns,
                   item_path => Path,
                   schema => Schema}}
    end.

key_tuple(ListPath, #{key_names := Names, config := Config}, KeyStrs) ->
    case length(Names) =:= length(KeyStrs) of
        false ->
            {error, #{tag => <<"invalid-value">>,
                      http => 400,
                      message => "incorrect number of list keys"}};
        true ->
            case cast_keys(ListPath, Names, KeyStrs, []) of
                {ok, Internal} ->
                    Tuple = case Config of
                                false -> list_to_tuple(Internal);
                                _ -> list_to_tuple(KeyStrs)
                            end,
                    {ok, Tuple};
                {error, _} = Err ->
                    Err
            end
    end.

cast_keys(_ListPath, [], [], Acc) ->
    {ok, lists:reverse(Acc)};
cast_keys(ListPath, [Name | Names], [Val | Vals], Acc) ->
    case mgmtd_schema:lookup(ListPath ++ [Name]) of
        #{type := Type} ->
            case mgmtd_schema:cast(Type, Val) of
                {ok, Internal} ->
                    cast_keys(ListPath, Names, Vals, [Internal | Acc]);
                {error, Reason} ->
                    {error, #{tag => <<"invalid-value">>,
                              http => 400,
                              message => key_error(Name, Reason)}}
            end;
        _ ->
            {error, #{tag => <<"invalid-value">>,
                      http => 400,
                      message => "missing key leaf " ++ Name}}
    end.

key_error(Name, Reason) when is_list(Reason) ->
    "invalid key " ++ Name ++ ": " ++ Reason;
key_error(Name, Reason) ->
    lists:flatten(io_lib:format("invalid key ~s: ~p", [Name, Reason])).

-spec data_uri(map()) -> binary().
data_uri(#{module := Module, prefix := Prefix, item_path := Path}) ->
    Local = strip_prefix(Prefix, Path),
    iolist_to_binary(["/restconf/data/", format_local(Module, Local)]).

strip_prefix(?DEFAULT_NS, Path) ->
    Path;
strip_prefix(Prefix, [Name | Rest] = Path) ->
    case atom_to_list(Prefix) of
        Name -> Rest;
        _ -> Path
    end;
strip_prefix(_Prefix, Path) ->
    Path.

format_local(_Module, []) ->
    [];
format_local(Module, [Name | Rest]) when is_list(Name) ->
    format_more(Rest, [Module, $:, Name]).

format_more([], Acc) ->
    Acc;
format_more([Key | Rest], Acc) when is_tuple(Key) ->
    format_more(Rest, [Acc, $=, join_keys(Key)]);
format_more([Name | Rest], Acc) when is_list(Name) ->
    format_more(Rest, [Acc, $/, Name]).

join_keys(Key) ->
    Parts = [percent_encode(key_part(P)) || P <- tuple_to_list(Key)],
    lists:join($,, Parts).

key_part(S) when is_list(S) ->
    S;
key_part(N) when is_integer(N) ->
    integer_to_list(N);
key_part(T) when is_tuple(T), tuple_size(T) =:= 4; tuple_size(T) =:= 8 ->
    inet:ntoa(T);
key_part(B) when is_binary(B) ->
    binary_to_list(B);
key_part(A) when is_atom(A) ->
    atom_to_list(A).

percent_encode(Str) ->
    lists:flatten([pct_char(C) || C <- Str]).

pct_char(C) when C >= $a, C =< $z -> C;
pct_char(C) when C >= $A, C =< $Z -> C;
pct_char(C) when C >= $0, C =< $9 -> C;
pct_char(C) when C =:= $-; C =:= $.; C =:= $_; C =:= $~ -> C;
pct_char(C) ->
    io_lib:format("%~2.16.0B", [C]).

prefix_base(?DEFAULT_NS) ->
    [];
prefix_base(Prefix) ->
    [atom_to_list(Prefix)].

module_name(Prefix) ->
    case [M || #{prefix := P, module := M} <- mgmtd_schema:loaded_schema_infos(),
               P =:= Prefix] of
        [M] ->
            M;
        _ ->
            atom_to_list(Prefix)
    end.

parse_ident(Seg, CurMod) ->
    {NamePart, Keys} =
        case binary:split(Seg, <<"=">>) of
            [Bare] ->
                {Bare, undefined};
            [Bare, KeyBin] ->
                {Bare, [percent_decode(P)
                        || P <- binary:split(KeyBin, <<",">>, [global])]}
        end,
    case binary:split(NamePart, <<":">>) of
        [ModBin, NameBin] ->
            {binary_to_list(ModBin), binary_to_list(NameBin), Keys};
        [NameBin] when CurMod =/= undefined ->
            {CurMod, binary_to_list(NameBin), Keys};
        [_BareName] ->
            {error, #{tag => <<"invalid-value">>,
                      http => 400,
                      message => <<"top-level identifier must be module:name">>}};
        _ ->
            {error, #{tag => <<"invalid-value">>,
                      http => 400,
                      message => <<"invalid identifier">>}}
    end.

split_slash(Bin) ->
    [S || S <- binary:split(Bin, <<"/">>, [global]), S =/= <<>>].

percent_decode(Bin) ->
    percent_decode(binary_to_list(Bin), []).

percent_decode([$%, H, L | Rest], Acc) ->
    case hex_byte(H, L) of
        {ok, C} ->
            percent_decode(Rest, [C | Acc]);
        error ->
            percent_decode([H, L | Rest], [$% | Acc])
    end;
percent_decode([C | Rest], Acc) ->
    percent_decode(Rest, [C | Acc]);
percent_decode([], Acc) ->
    lists:reverse(Acc).

hex_byte(H, L) ->
    case {hex_val(H), hex_val(L)} of
        {HV, LV} when is_integer(HV), is_integer(LV) ->
            {ok, HV * 16 + LV};
        _ ->
            error
    end.

hex_val(C) when C >= $0, C =< $9 -> C - $0;
hex_val(C) when C >= $a, C =< $f -> C - $a + 10;
hex_val(C) when C >= $A, C =< $F -> C - $A + 10;
hex_val(_) -> error.
