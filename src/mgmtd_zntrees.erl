%%%-------------------------------------------------------------------
%%% @author Sean Hinde <sean@Seans-MacBook.local>
%%% @doc zntrees module taken from ferd.ca blogpost:
%%%      https://ferd.ca/yet-another-article-on-zippers.html
%%%
%%% @end
%%% Created : 26 Sep 2019 by Sean Hinde <sean@Seans-MacBook.local>
%%%-------------------------------------------------------------------
-module(mgmtd_zntrees).

-export([root/1, value/1,
         replace/2, insert/2, delete/1,
         left/1, right/1, children/1, parent/1, rparent/1]).

-type zlist(A) :: {Left::list(A), Right::list(A)}.
-type znode()  :: zlist({term(), zlist(_)}). % znode is a zlist of nodes
-type thread() :: [znode()].
-type zntree() :: {thread(), znode()}.

-export_type([zntree/0]).

%% creates a tree with an empty thread and Val as the root.
-spec root(term()) -> zntree().
root(Val) -> {[], {[], [{Val, {[], []}}]}}.

%% Extracts the node's value from the current tree position.
-spec value(zntree()) -> term().
value({_Thread, {_Left, [{Val, _Children} | _Right]}}) -> Val.

%% Replaces the value from at the current tree position, without touching
%% the children nodes.
-spec replace(term(), zntree()) -> zntree().
replace(Val, {T, {L, [{_Val, Children}|R]}}) ->
    {T, {L, [{Val,Children}|R]}}.

%% Add a new node at the current position with the value Val.
-spec insert(term(), zntree()) -> zntree().
insert(Val, {Thread, {L, R}}) ->
    {Thread, {L, [{Val, {[], []}} | R]}}.

%% Deletes the node at the current position and its children.
%% The next one on the right becomes the current position.
-spec delete(zntree()) -> zntree().
delete({Thread, {L, [_|R]}}) ->
    {Thread, {L, R}}.

%% Moves to the left of the current level.
-spec left(zntree()) -> zntree().
left({Thread, {[H|T], R}}) ->
    {Thread, {T, [H|R]}}.

%% Moves to the right of the current level
-spec right(zntree()) -> zntree().
right({Thread, {L, [H|T]}}) ->
    {Thread, {[H|L], T}}.

%% Goes down one level to the children of the current node.
%% Note that in order for this to work, the {Val, Children} tuple
%% needs to be broken in two: the value goes in the Thread's zlist
%% while the Children become the current level.
-spec children(zntree()) -> zntree().
children({Thread, {L, [{Val, Children}|R]}}) ->
    {[{L,[Val|R]}|Thread], Children}.

%% Moves up to the direct parent level. Doesn't rewind the current
%% level's zlist. This means that if you have a tree, go to the
%% children, browse to the right 2-3 times, then go back up and
%% down to the children again, you'll be at the same position you were
%% before.
%% If you prefer the children to be 'rewinded', use rparent/1.
-spec parent(zntree()) -> zntree().
parent({[{L, [Val|R]}|Thread], Children}) ->
    {Thread, {L, [{Val, Children}|R]}}.

%% Moves up to the direct parent level, much like parent/1. However,
%% it rewinds the current level's zlist before doing so. This allows
%% the programmer to access children as if it were the first time,
%% all the time.
-spec rparent(zntree()) -> zntree().
rparent({[{ParentL, [Val|ParentR]}|Thread], {L, R}}) ->
    {Thread, {ParentL, [{Val, {[], lists:reverse(L)++R}}|ParentR]}}.
