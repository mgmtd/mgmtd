%% YANG compact-syntax statement parser (pure Erlang).
%%
%% Statement tree: {Keyword, Line, Arg, [Stmt]}
%% Keyword is a core-statement atom, {PrefixBin, NameBin} for extensions,
%% or a binary for unknown identifiers.
%%
%% Fold algorithm derived from tonyrog/yang `yang_parser.erl` (MIT):
%% Copyright (C) 2007-2012 Rogvall Invest AB <tony@rogvall.se>
-module(mgmtd_yang_parse).

-export([file/1, file/2, string/1]).
-export([parse/1, parse/2]).

-export_type([stmt/0, keyword/0, arg/0]).

-type line() :: pos_integer().
-type keyword() :: atom() | binary() | {binary(), binary()}.
-type arg() :: binary() | atom() | [].
-type stmt() :: {keyword(), line(), arg(), [stmt()]}.

-spec file(file:filename()) -> {ok, [stmt()]} | {error, term()}.
file(File) ->
    file(File, []).

-spec file(file:filename(), proplists:proplist()) ->
          {ok, [stmt()]} | {error, term()}.
file(File, Opts) ->
    parse(File, Opts).

-spec string(binary() | string()) -> {ok, [stmt()]} | {error, term()}.
string(Text) ->
    case mgmtd_yang_scan:string(Text) of
        {ok, Scan} ->
            fold_stmt(fun collect/5, [], Scan)
    end.

-spec parse(file:filename()) -> {ok, [stmt()]} | {error, term()}.
parse(File) ->
    parse(File, []).

-spec parse(file:filename(), proplists:proplist()) ->
          {ok, [stmt()]} | {error, term()}.
parse(File, Opts) ->
    case mgmtd_yang_scan:open(File, Opts) of
        {ok, Scan} ->
            Res = fold_stmt(fun collect/5, [], Scan),
            mgmtd_yang_scan:close(Scan),
            Res;
        Error ->
            Error
    end.

collect(Key, Ln, Arg, Acc0, Acc) ->
    {true, [{Key, Ln, Arg, lists:reverse(Acc0)} | Acc]}.

fold_stmt(Fun, Acc0, Scan) ->
    fold_stmt(Fun, Acc0, Acc0, Scan, 0).

fold_stmt(Fun, Acc, Acc0, Scan, Depth) ->
    case mgmtd_yang_scan:next(Scan) of
        {{word, Ln, Stmt}, Scan1} ->
            case mgmtd_yang_scan:next(Scan1) of
                {{string, _, Arg}, Scan2} ->
                    fold_stmt_list(Stmt, Ln, Arg, Fun, Acc, Acc0, Scan2, Depth);
                {{word, _, Arg}, Scan2} ->
                    fold_stmt_list(Stmt, Ln, Arg, Fun, Acc, Acc0, Scan2, Depth);
                {Token = {_, _}, Scan2} ->
                    Scan3 = mgmtd_yang_scan:push_back(Token, Scan2),
                    fold_stmt_list(Stmt, Ln, [], Fun, Acc, Acc0, Scan3, Depth);
                eof ->
                    {error, {Ln, "statement ~s not terminated", [Stmt]}};
                Error ->
                    Error
            end;
        {{string, Ln, Stmt}, _Scan1} ->
            {error, {Ln, "string ~s not expected", [Stmt]}};
        {{'}', _Ln}, Scan2} when Depth > 0 ->
            {stmt_list, Scan2, Acc};
        eof when Depth =:= 0 ->
            {ok, lists:reverse(Acc)};
        {{T, Ln}, _Scan2} when is_atom(T) ->
            {error, {Ln, "token ~w not expected", [T]}};
        Error ->
            Error
    end.

fold_stmt_list(Key, Ln, Arg, Fun, Acc, Acc0, Scan, Depth) ->
    case mgmtd_yang_scan:next(Scan) of
        {{';', _}, Scan1} ->
            case callback(Fun, Key, Ln, Arg, Acc0, Acc) of
                {true, Acc1} ->
                    fold_stmt(Fun, Acc1, Acc0, Scan1, Depth);
                true ->
                    fold_stmt(Fun, Acc, Acc0, Scan1, Depth);
                Result ->
                    Result
            end;
        {{'{', _}, Scan1} ->
            case fold_stmt(Fun, Acc0, Acc0, Scan1, Depth + 1) of
                {stmt_list, Scan2, Acc2} ->
                    case callback(Fun, Key, Ln, Arg, Acc2, Acc) of
                        {true, Acc1} ->
                            fold_stmt(Fun, Acc1, Acc0, Scan2, Depth);
                        true ->
                            fold_stmt(Fun, Acc, Acc0, Scan2, Depth);
                        Result ->
                            Result
                    end;
                Result ->
                    Result
            end;
        eof ->
            {error, {Ln, "statement ~s not terminated", [Key]}};
        {{word, Ln1, _}, _} ->
            {error, {Ln1, "syntax error after ~s", [Key]}};
        {{string, Ln1, _}, _} ->
            {error, {Ln1, "syntax error after ~s", [Key]}};
        Error ->
            Error
    end.

callback(Fun, Key, Ln, Arg, Acc0, Acc) ->
    Fun(stmt_keyword(Key), Ln, other_keyword(Arg), Acc0, Acc).

stmt_keyword(Bin) when is_binary(Bin) ->
    case Bin of
        <<"anydata">> -> 'anydata';
        <<"anyxml">> -> 'anyxml';
        <<"argument">> -> 'argument';
        <<"augment">> -> 'augment';
        <<"base">> -> 'base';
        <<"belongs-to">> -> 'belongs-to';
        <<"bit">> -> 'bit';
        <<"case">> -> 'case';
        <<"choice">> -> 'choice';
        <<"config">> -> 'config';
        <<"contact">> -> 'contact';
        <<"container">> -> 'container';
        <<"default">> -> 'default';
        <<"description">> -> 'description';
        <<"enum">> -> 'enum';
        <<"error-app-tag">> -> 'error-app-tag';
        <<"error-message">> -> 'error-message';
        <<"extension">> -> 'extension';
        <<"deviation">> -> 'deviation';
        <<"deviate">> -> 'deviate';
        <<"feature">> -> 'feature';
        <<"fraction-digits">> -> 'fraction-digits';
        <<"grouping">> -> 'grouping';
        <<"identity">> -> 'identity';
        <<"if-feature">> -> 'if-feature';
        <<"import">> -> 'import';
        <<"include">> -> 'include';
        <<"input">> -> 'input';
        <<"key">> -> 'key';
        <<"leaf">> -> 'leaf';
        <<"leaf-list">> -> 'leaf-list';
        <<"length">> -> 'length';
        <<"list">> -> 'list';
        <<"mandatory">> -> 'mandatory';
        <<"max-elements">> -> 'max-elements';
        <<"min-elements">> -> 'min-elements';
        <<"modifier">> -> 'modifier';
        <<"module">> -> 'module';
        <<"must">> -> 'must';
        <<"namespace">> -> 'namespace';
        <<"notification">> -> 'notification';
        <<"ordered-by">> -> 'ordered-by';
        <<"organization">> -> 'organization';
        <<"output">> -> 'output';
        <<"path">> -> 'path';
        <<"pattern">> -> 'pattern';
        <<"position">> -> 'position';
        <<"prefix">> -> 'prefix';
        <<"presence">> -> 'presence';
        <<"range">> -> 'range';
        <<"reference">> -> 'reference';
        <<"refine">> -> 'refine';
        <<"require-instance">> -> 'require-instance';
        <<"revision">> -> 'revision';
        <<"revision-date">> -> 'revision-date';
        <<"rpc">> -> 'rpc';
        <<"action">> -> 'action';
        <<"status">> -> 'status';
        <<"submodule">> -> 'submodule';
        <<"type">> -> 'type';
        <<"typedef">> -> 'typedef';
        <<"unique">> -> 'unique';
        <<"units">> -> 'units';
        <<"uses">> -> 'uses';
        <<"value">> -> 'value';
        <<"when">> -> 'when';
        <<"yang-version">> -> 'yang-version';
        <<"yin-element">> -> 'yin-element';
        _ ->
            case binary:split(Bin, <<":">>) of
                [Prefix, Name] ->
                    {Prefix, Name};
                [_Name] ->
                    Bin
            end
    end.

other_keyword(Bin) when is_binary(Bin) ->
    case Bin of
        <<"add">> -> 'add';
        <<"current">> -> 'current';
        <<"delete">> -> 'delete';
        <<"deprecated">> -> 'deprecated';
        <<"false">> -> 'false';
        <<"invert-match">> -> 'invert-match';
        <<"max">> -> 'max';
        <<"min">> -> 'min';
        <<"not-supported">> -> 'not-supported';
        <<"obsolete">> -> 'obsolete';
        <<"replace">> -> 'replace';
        <<"system">> -> 'system';
        <<"true">> -> 'true';
        <<"unbounded">> -> 'unbounded';
        <<"user">> -> 'user';
        _ -> Bin
    end;
other_keyword(Other) ->
    Other.
