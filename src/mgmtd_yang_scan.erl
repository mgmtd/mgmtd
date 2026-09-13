%% YANG compact-syntax scanner (pure Erlang).
%%
%% Portions derived from tonyrog/yang `yang_scan_erl.erl` (MIT):
%% Copyright (C) 2007-2012 Rogvall Invest AB <tony@rogvall.se>
%%
%% Token stream: {word, Line, binary()} | {string, Line, binary()} |
%%               {'{', Line} | {'}', Line} | {';', Line}.
-module(mgmtd_yang_scan).

-export([open/1, open/2, string/1, next/1, push_back/2, close/1]).
-export([file/1, file/2, all/1]).

-export_type([token/0, scan/0]).

-type line() :: pos_integer().
-type token() :: {string, line(), binary()}
               | {word, line(), binary()}
               | {'{', line()}
               | {'}', line()}
               | {';', line()}.

-record(yang_scan, {
          buffer = [] :: string(),
          tokens = [] :: [token() | eof],
          line = 1 :: line(),
          column = 1 :: pos_integer(),
          stream :: undefined | {file:io_device(), pos_integer()}
         }).

-opaque scan() :: #yang_scan{}.

-spec file(file:filename()) -> {ok, [token()]} | {error, term()}.
file(File) ->
    file(File, []).

-spec file(file:filename(), proplists:proplist()) ->
          {ok, [token()]} | {error, term()}.
file(File, Opts) ->
    case open(File, Opts) of
        {ok, Scan} ->
            Res = all(Scan),
            close(Scan),
            Res;
        Error ->
            Error
    end.

-spec open(file:filename()) -> {ok, scan()} | {error, term()}.
open(File) ->
    open(File, []).

-spec open(file:filename(), proplists:proplist()) ->
          {ok, scan()} | {error, term()}.
open(File, Opts) ->
    ChunkSize = proplists:get_value(chunk_size, Opts, 1024),
    case open_file(File, Opts) of
        {ok, Fd} ->
            {ok, #yang_scan{stream = {Fd, ChunkSize}}};
        Error ->
            Error
    end.

open_file(File, Opts) ->
    case lists:keyfind(open_hook, 1, Opts) of
        false ->
            file:open(File, [read, raw, binary]);
        {_, Fun} when is_function(Fun, 2) ->
            Fun(File, Opts)
    end.

-spec string(binary() | string()) -> {ok, scan()}.
string(Binary) when is_binary(Binary) ->
    {ok, #yang_scan{buffer = binary_to_list(Binary)}};
string(List) when is_list(List) ->
    {ok, #yang_scan{buffer = List}}.

-spec close(scan()) -> ok | {error, term()}.
close(#yang_scan{stream = undefined}) ->
    ok;
close(#yang_scan{stream = {Fd, _}}) ->
    file:close(Fd).

-spec all(scan()) -> {ok, [token()]} | {error, term()}.
all(Scan) ->
    all(Scan, []).

all(Scan, Acc) ->
    case next(Scan) of
        {error, _} = Error ->
            Error;
        eof ->
            {ok, lists:reverse(Acc)};
        {Token, Scan1} ->
            all(Scan1, [Token | Acc])
    end.

-spec push_back(token(), scan()) -> scan().
push_back(Token, #yang_scan{tokens = Ts} = Scan) ->
    Scan#yang_scan{tokens = [Token | Ts]}.

-spec next(scan()) -> {token(), scan()} | eof | {error, term()}.
next(#yang_scan{buffer = B, line = L, column = C, stream = S, tokens = []}) ->
    case wsp(B, L, C, S) of
        {{string, _, _} = Token, Scan1} ->
            next_string(Scan1, Token);
        Other ->
            Other
    end;
next(#yang_scan{tokens = [T | Ts]} = Scan) ->
    case T of
        eof ->
            eof;
        Token ->
            {Token, Scan#yang_scan{tokens = Ts}}
    end.

next_string(Scan, StringToken) ->
    case wsp(Scan) of
        {{word, _, <<"+">>} = PlusToken, Scan1} ->
            next_concat(Scan1, StringToken, PlusToken);
        {error, _} = Error ->
            Error;
        {Token, Scan1} ->
            {StringToken, Scan1#yang_scan{tokens = [Token]}};
        eof ->
            {StringToken, Scan#yang_scan{tokens = [eof]}}
    end.

next_concat(Scan, {string, Ln, Str1} = StringToken, PlusToken) ->
    case wsp(Scan) of
        {{string, _, Str2}, Scan1} ->
            next_string(Scan1, {string, Ln, <<Str1/binary, Str2/binary>>});
        {error, _} = Error ->
            Error;
        {Token, Scan1} ->
            {StringToken, Scan1#yang_scan{tokens = [PlusToken, Token]}};
        eof ->
            {StringToken, Scan#yang_scan{tokens = [PlusToken, eof]}}
    end.

wsp(#yang_scan{buffer = B, line = L, column = C, stream = S}) ->
    wsp(B, L, C, S).

wsp([$/, $/ | B], L, C, S) ->
    line_comment(B, L, C, S);
wsp([$/, $* | B], L, C, S) ->
    block_comment(B, L, C, S);
wsp([$/], L, C, S) ->
    case read(S) of
        {ok, B} -> wsp([$/ | B], L, C, S);
        eof -> eof;
        Error -> Error
    end;
wsp([A | B], L, C, S) ->
    case A of
        $\s -> wsp(B, L, C + 1, S);
        $\t -> wsp(B, L, C + 8, S);
        $\r -> wsp(B, L, C, S);
        $\n -> wsp(B, L + 1, 1, S);
        $" -> dquote_string(B, [], L, C, L, C + 1, false, S);
        $' -> squote_string(B, [], L, L, C + 1, S);
        ${ -> token_(B, '{', L, C + 1, S);
        $} -> token_(B, '}', L, C + 1, S);
        $; -> token_(B, ';', L, C + 1, S);
        _ -> word(B, [A], L, C + 1, S)
    end;
wsp([], L, C, S) ->
    case read(S) of
        {ok, B0} -> wsp(B0, L, C, S);
        eof -> eof;
        Error -> Error
    end.

word(B0 = [$/, $/ | _], Acc, L, C, S) ->
    word_(B0, Acc, L, C, S);
word(B0 = [$/, $* | _], Acc, L, C, S) ->
    word_(B0, Acc, L, C, S);
word([$/], Acc, L, C, S) ->
    case read(S) of
        {ok, B} -> word([$/ | B], Acc, L, C, S);
        eof -> word_([], Acc, L, C, S);
        Error -> Error
    end;
word(B0 = [A | B], Acc, L, C, S) ->
    case A of
        $\s -> word_(B, Acc, L, C + 1, S);
        $\t -> word_(B, Acc, L, C + 8, S);
        $\r -> word_(B, Acc, L, C, S);
        $\n -> word_(B0, Acc, L, C, S);
        $; -> word_(B0, Acc, L, C, S);
        ${ -> word_(B0, Acc, L, C, S);
        $} -> word_(B0, Acc, L, C, S);
        _ -> word(B, [A | Acc], L, C + 1, S)
    end;
word([], Acc, L, C, S) ->
    case read(S) of
        {ok, B1} -> word(B1, Acc, L, C, S);
        eof -> word_([], Acc, L, C, S);
        Error -> Error
    end.

%% Double-quoted string. After a newline, leading whitespace is stripped
%% up to the column of the opening quote (RFC 7950 §6.1.3).
dquote_string([$\\, A | B], Acc, L0, C0, L, C, _W, S) ->
    case A of
        $n -> dquote_string(B, [$\n | Acc], L0, C0, L, C, false, S);
        $t -> dquote_string(B, [$\t | Acc], L0, C0, L, C, false, S);
        $" -> dquote_string(B, [A | Acc], L0, C0, L, C, false, S);
        $\\ -> dquote_string(B, [A | Acc], L0, C0, L, C, false, S);
        _ -> dquote_string(B, [A, $\\ | Acc], L0, C0, L, C, false, S)
    end;
dquote_string([$\\], Acc, L0, C0, L, C, W, S) ->
    case read(S) of
        {ok, B1} -> dquote_string([$\\ | B1], Acc, L0, C0, L, C, W, S);
        eof -> {error, {L, unterminated_string}};
        Error -> Error
    end;
dquote_string([A | B], Acc, L0, C0, L, C, W, S) ->
    case A of
        $" ->
            string_(B, lists:reverse(Acc), L0, L, C + 1, S);
        $\n ->
            Acc1 = trim_wsp(Acc),
            dquote_string(B, [A | Acc1], L0, C0, L + 1, 1, true, S);
        $\s when W, C =< C0 ->
            dquote_string(B, Acc, L0, C0, L, C + 1, W, S);
        $\s ->
            dquote_string(B, [A | Acc], L0, C0, L, C + 1, false, S);
        $\t when W, C =< C0 ->
            dquote_string(B, Acc, L0, C0, L, C + 8, W, S);
        $\t ->
            dquote_string(B, [A | Acc], L0, C0, L, C + 8, false, S);
        _ ->
            dquote_string(B, [A | Acc], L0, C0, L, C + 1, false, S)
    end;
dquote_string([], Acc, L0, C0, L, C, W, S) ->
    case read(S) of
        {ok, B1} -> dquote_string(B1, Acc, L0, C0, L, C, W, S);
        eof -> {error, {L, unterminated_string}};
        Error -> Error
    end.

squote_string([], Acc, L0, L, C, S) ->
    case read(S) of
        {ok, B1} -> squote_string(B1, Acc, L0, L, C, S);
        eof -> {error, {L, unterminated_string}};
        Error -> Error
    end;
squote_string([A | B], Acc, L0, L, C, S) ->
    case A of
        $' -> string_(B, lists:reverse(Acc), L0, L, C + 1, S);
        $\n -> squote_string(B, [A | Acc], L0, L + 1, 1, S);
        _ -> squote_string(B, [A | Acc], L0, L, C + 1, S)
    end.

line_comment([$\n | B], L, _C, S) ->
    wsp(B, L + 1, 1, S);
line_comment([_ | B], L, C, S) ->
    line_comment(B, L, C + 1, S);
line_comment([], L, C, S) ->
    case read(S) of
        {ok, B1} -> line_comment(B1, L, C, S);
        eof -> eof;
        Error -> Error
    end.

block_comment([$*, $/ | B], L, C, S) ->
    wsp(B, L, C + 2, S);
block_comment([$*], L, C, S) ->
    case read(S) of
        {ok, B1} -> block_comment([$* | B1], L, C, S);
        eof -> {error, {L, unterminated_comment}};
        Error -> Error
    end;
block_comment([$\n | B], L, _C, S) ->
    block_comment(B, L + 1, 1, S);
block_comment([_ | B], L, C, S) ->
    block_comment(B, L, C + 1, S);
block_comment([], L, C, S) ->
    case read(S) of
        {ok, B1} -> block_comment(B1, L, C, S);
        eof -> {error, {L, unterminated_comment}};
        Error -> Error
    end.

trim_wsp([$\s | Cs]) -> trim_wsp(Cs);
trim_wsp([$\t | Cs]) -> trim_wsp(Cs);
trim_wsp(Cs) -> Cs.

string_(B, Str, L0, L, C, S) ->
    {{string, L0, list_to_binary(Str)},
     #yang_scan{buffer = B, line = L, column = C, stream = S}}.

word_(B, Acc, L, C, S) ->
    {{word, L, list_to_binary(lists:reverse(Acc))},
     #yang_scan{buffer = B, line = L, column = C, stream = S}}.

token_(B, Tok, L, C, S) ->
    {{Tok, L},
     #yang_scan{buffer = B, line = L, column = C, stream = S}}.

read(undefined) ->
    eof;
read({Fd, Size}) ->
    case file:read(Fd, Size) of
        {ok, Bin} when is_binary(Bin) -> {ok, binary_to_list(Bin)};
        {ok, List} when is_list(List) -> {ok, List};
        Error -> Error
    end.
